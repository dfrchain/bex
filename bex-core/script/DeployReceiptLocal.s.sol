// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { PaymentReceiptSink } from "../src/PaymentReceiptSink.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @notice Local live-chain scaffold: deploy sink + token, make a real pay() call, and print the receipt hash.
/// @dev Purpose: produce **real eth_getProof vectors** (mandated by the third review round),
///      rather than self-consistent Python vectors.
contract DeployReceiptLocal is Script {
    function run() external {
        vm.startBroadcast();
        MockERC20 token = new MockERC20("Mock", "MCK", 6);
        address[] memory allowed = new address[](1);
        allowed[0] = address(token);
        PaymentReceiptSink sink = new PaymentReceiptSink(allowed);
        address solver = msg.sender;
        address recipient = address(0xBEEF);
        token.mint(solver, 1_000_000e6);
        token.approve(address(sink), type(uint256).max);
        bytes32 rh = sink.pay(1, 100, 31337, recipient, address(token), 1000e6);
        vm.stopBroadcast();
        console2.log("TOKEN", address(token));
        console2.log("SINK", address(sink));
        console2.log("SOLVER", solver);
        console2.log("RECIPIENT", recipient);
        console2.logBytes32(rh);
    }
}
