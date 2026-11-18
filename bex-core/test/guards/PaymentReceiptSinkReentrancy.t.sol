// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { PaymentReceiptSink } from "src/PaymentReceiptSink.sol";

/// @notice Malicious ERC-20: calls back into `PaymentReceiptSink.pay` from `transferFrom`,
///         trying to cut in a second payment before the original call finishes.
contract ReentrantPaymentToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public innerCalldata;
    bool public reentryAttempted;
    bool public reentryBlocked;
    bool private _entered;

    function configure(address target_, bytes calldata innerCalldata_) external {
        target = target_;
        innerCalldata = innerCalldata_;
        // Give the token contract itself a balance and sink approval, so the inner pay could have succeeded **without the lock**.
        // Otherwise the inner call would revert for insufficient balance and the test would become a false positive.
        balanceOf[address(this)] = 1_000_000;
        allowance[address(this)][target_] = type(uint256).max;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        // Only attempt reentrancy once, on the outermost transfer, to avoid infinite recursion drowning the assertions.
        if (target != address(0) && !_entered) {
            _entered = true;
            reentryAttempted = true;
            (bool ok,) = target.call(innerCalldata);
            reentryBlocked = !ok;
            _entered = false;
        }
        return true;
    }
}

/// @notice Regression: the reentrancy lock in `PaymentReceiptSink.pay` must actually block callback-style tokens.
/// @dev Attack model: a malicious token calls back into `pay` from `transferFrom`. The lock must make the inner call fail with
///      `Reentrant`, while the outer payment still succeeds and the receipt is written only once.
contract PaymentReceiptSinkReentrancyTest is Test {
    function _oneAsset(address a) internal pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = a;
    }

    function test_ReentrantTokenCannotReenterPay() public {
        ReentrantPaymentToken token = new ReentrantPaymentToken();
        PaymentReceiptSink sink = new PaymentReceiptSink(_oneAsset(address(token)));

        address recipient = address(0xB0B);
        token.mint(address(this), 1_000_000);
        token.approve(address(sink), type(uint256).max);

        // Inner callback: call pay once more with a different orderId, trying to cut in before the original call finishes.
        bytes memory inner = abi.encodeWithSignature(
            "pay(uint256,uint256,uint64,address,address,uint256)",
            1,
            999,
            uint64(31337),
            recipient,
            address(token),
            1_000
        );
        token.configure(address(sink), inner);

        bytes32 outerHash = sink.pay(1, 1, 31337, recipient, address(token), 1_000);

        assertTrue(token.reentryAttempted(), "callback must have been attempted");
        assertTrue(token.reentryBlocked(), "inner pay must be rejected by the reentrancy lock");
        assertTrue(sink.isPaid(outerHash), "outer payment must still settle");
    }
}
