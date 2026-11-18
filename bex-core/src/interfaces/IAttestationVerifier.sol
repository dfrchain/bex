// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Receipt verification module interface
/// @notice The first version is 3-of-5 multisig; the second version can swap in threshold signatures, and the third can swap in a light client or proof verification.
///         Swapping must not change Settlement's business logic (`04-interface-and-state-machine-spec.md` §2.4).
interface IAttestationVerifier {
    function verify(bytes32 digest, bytes calldata proof) external view returns (bool);
}
