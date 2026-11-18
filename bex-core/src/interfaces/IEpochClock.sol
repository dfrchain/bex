// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Batch clock interface
/// @notice Per-tier verifiers need to know "when this batch ends and when the reveal must be complete",
///         but do not need to know the rest of the order book. Both `OrderBook` and `SealedOrderBook` satisfy this interface.
interface IEpochClock {
    /// @notice Batch end height (exclusive).
    function epochEndBlock(uint64 epoch) external view returns (uint256);

    /// @notice Receipt/refund deadline height.
    function epochDeadlineBlock(uint64 epoch) external view returns (uint256);
}
