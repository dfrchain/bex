// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Signer attribution interface (BEX-21 option B)
/// @notice Beyond the boolean semantics of `IAttestationVerifier.verify`, deterministically recover from a proof
///         the subset of **valid, distinct** signers — the prerequisite for slash attribution (decision pack §4.3).
///         Whether the threshold is met is for the caller to decide; this interface changes no semantics of `verify`.
interface ISignerRecovery {
    function recoverValidSigners(bytes32 digest, bytes calldata proof) external view returns (address[] memory);
}
