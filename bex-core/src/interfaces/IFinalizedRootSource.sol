// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Finalized root source interface
/// @notice The D1 abstraction for G-2: a verifier only needs to know "whether the root at a given height is trustworthy and consistent",
///         and does not care whether that verdict comes from a "trusted reporter" or from "stake + challenge".
/// @dev Why this must be abstracted: if `StateProofReceiptVerifier` hard-binds a concrete type, it can only choose between
///      `FinalizedStateOracle` (simple but fully trusts the reporter) and `OptimisticStateOracle`
///      (trust-minimized but has a window). Once extracted into an interface, the same verifier and the same
///      `Settlement` can pick any root source at deploy time without changing any business logic.
interface IFinalizedRootSource {
    /// @notice Whether this height already has a **usable** root that matches the given value.
    /// @dev Implementations must fail closed: roots still in-window, not yet finalized, or invalidated must all return false.
    function matches(uint256 height, bytes32 root) external view returns (bool);
}
