// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IAttestationVerifier } from "./IAttestationVerifier.sol";

/// @title G-2/G-3 receipt proof verifier interface
/// @notice Occupies the same slot as `IAttestationVerifier` (`Settlement.settle` only calls `verify`),
///         but additionally exposes two **read-only metadata** fields so monitors and reviewers can see directly "what root this chain relies on, and what kind of proof":
///         `proofKind()` (proof system) and `rootSource()` (where the root comes from).
/// @dev Why freeze the interface now: swapping `IAttestationVerifier` in G-1 already proved "the verifier can be swapped without changing Settlement".
///      (see `docs/33`); G-2 only needs the same function signature to swap in place. Freezing the interface costs very little,
///      while waiting until implementation time to define it would force the settlement layer to be reworked.
/// @dev Boundary (`docs/34` §2): the interface itself guarantees no security — D1 (trusted root) / D2 (proof path) /
///      D3 (decidable semantics) / D4 (fail-closed failure modes) must be confirmed item by item on the destination chain.
interface IReceiptProofVerifier is IAttestationVerifier {
    /// @notice Proof system identifier: 1 = multisig (G-1), 2 = MPT state proof, 3 = zkVM/zk proof; the rest are reserved for the future.
    function proofKind() external view returns (uint8);

    /// @notice Description of the root's source (e.g. "L1 finalized stateRoot" / "OP output root via L1 contract").
    /// @dev Returning bytes32 is only a label for on-chain/off-chain alignment; the real semantics live in the deployment docs and `docs/34`.
    function rootSource() external view returns (bytes32);

    /// @notice Minimum challenge window (blocks) this proof system requires. The challenge window must be ≥ it, or proofs cannot be built in time.
    function minChallengeWindowBlocks() external view returns (uint256);
}
