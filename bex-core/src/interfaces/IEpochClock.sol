// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title 批次时钟接口
/// @notice 按档位实现的验证器需要知道"这一批什么时候结束、什么时候必须完成揭示"，
///         但不需要知道订单簿的其余部分。`OrderBook` 与 `SealedOrderBook` 都满足本接口。
interface IEpochClock {
    /// @notice 批次结束高度（不含）。
    function epochEndBlock(uint64 epoch) external view returns (uint256);

    /// @notice 回执/退款截止高度。
    function epochDeadlineBlock(uint64 epoch) external view returns (uint256);
}
