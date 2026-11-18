// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Versioned signer stake registry interface (BEX-21 option B)
/// @notice Minimal surface consumed by the `ChallengeableAttestation` add-on gate:
///         epoch snapshot thresholds, whether a signer is "in-snapshot + sufficiently locked + not exited", stake balances, and authorized slashing.
///         The full register/lock/exit API is in the `SignerStakeRegistry` contract itself.
interface ISignerStakeRegistry {
    /// @notice Signature threshold of the current snapshot for an epoch; returns 0 when there is no snapshot (callers fail closed on that).
    function snapshotThreshold(uint64 epoch) external view returns (uint256);
    /// @notice Whether signing power is valid: in the current snapshot, locked stake meets the snapshot requirement, and no exit requested.
    function isBondedSigner(uint64 epoch, address signer) external view returns (bool);
    /// @notice A signer's currently locked stake in an epoch.
    function stakeOf(uint64 epoch, address signer) external view returns (uint256);
    /// @notice Slash (only the single slasher bound at registration may call): capped by available stake, returns the actual slashed amount.
    function slash(uint64 epoch, address signer, uint256 amount, address to) external returns (uint256 slashed);
}
