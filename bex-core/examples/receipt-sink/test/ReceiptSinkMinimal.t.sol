// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { PaymentReceiptSink } from "../src/PaymentReceiptSink.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @notice Standalone no-cheatcode test of the public payment receipt path.
contract ReceiptSinkMinimalTest {
    function testPayCreatesExactReceiptAndRejectsDuplicate() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        PaymentReceiptSink sink = new PaymentReceiptSink(assets);
        token.mint(address(this), 100);
        token.approve(address(sink), 100);
        address receiver = address(0xBEEF);
        bytes32 expectedHash = sink.receiptHashOf(1, 7, 84532, uint64(block.chainid), address(this), receiver, address(token), 40);
        bytes32 actualHash = sink.pay(1, 7, 84532, receiver, address(token), 40);
        require(actualHash == expectedHash, "receipt hash mismatch");
        require(sink.isPaid(expectedHash), "receipt not stored");
        require(token.balanceOf(receiver) == 40, "recipient not paid");
        (bool ok,) = address(sink).call(abi.encodeCall(sink.pay, (1, 7, 84532, receiver, address(token), 40)));
        require(!ok, "duplicate payment accepted");
        require(token.balanceOf(receiver) == 40, "duplicate transferred funds");
    }

    function testRejectsAssetNotOnAllowlist() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        PaymentReceiptSink sink = new PaymentReceiptSink(assets);
        other.mint(address(this), 10);
        other.approve(address(sink), 10);
        (bool ok,) = address(sink).call(abi.encodeCall(sink.pay, (1, 7, 84532, address(0xBEEF), address(other), 10)));
        require(!ok, "unapproved asset accepted");
    }
}
