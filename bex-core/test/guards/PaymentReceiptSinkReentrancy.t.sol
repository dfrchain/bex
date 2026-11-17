// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { PaymentReceiptSink } from "src/PaymentReceiptSink.sol";

/// @notice 恶意 ERC-20：在 `transferFrom` 里回调 `PaymentReceiptSink.pay`，
///         想在原调用完成前插队第二笔付款。
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
        // 让代币合约自身有余额且已授权 sink，使内层 pay 在**没有锁**时本可成功。
        // 否则内层会因余额不足而 revert，测试就会变成假阳性。
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

        // 只在最外层转账时尝试一次重入，避免无限递归淹没断言。
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

/// @notice 回归：`PaymentReceiptSink.pay` 的重入锁必须真的挡住回调型代币。
/// @dev 攻击模型：恶意代币在 `transferFrom` 回调 `pay`。锁必须让内层调用以
///      `Reentrant` 失败，外层付款照常成功且回执只写一次。
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

        // 内层回调：换一个 orderId 再调一次 pay，试图在原调用未收尾时插队。
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
