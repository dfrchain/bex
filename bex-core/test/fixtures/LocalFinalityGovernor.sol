// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice INERT TEST ONLY. Not a Safe/multisig and NOT authorized for mainnet.
interface IFinalityDeployer {
    function deploy(uint64 activationDelay, uint64 firstSlot, uint64 lastSlot) external;
}

contract LocalFinalityGovernor {
    function deployLocalOnly(address target) external {
        require(block.chainid == 1, "Anvil local chain ID=1 fixture only");
        IFinalityDeployer(target).deploy(300, 100, 1000);
    }
}

contract LocalFinalityGuardian { }
