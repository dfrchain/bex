// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { PaymentReceiptSink } from "../src/PaymentReceiptSink.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @notice 本地真链脚手：部署 sink + token，真实调用 pay()，打印回执哈希。
/// @dev 目的：产出**真实 eth_getProof 向量**（评审第三轮强制要求），
///      而不是自洽的 Python 向量。
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
