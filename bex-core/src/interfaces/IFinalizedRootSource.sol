// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title 最终化根来源接口
/// @notice G-2 的 D1 抽象：验证器只需要知道"某高度的根是否可信且一致"，
///         不关心这个判定是"可信报告者"还是"质押 + 挑战"得来的。
/// @dev 为什么必须抽象：`StateProofReceiptVerifier` 若硬绑具体类型，就只能在
///      `FinalizedStateOracle`（简单但完全信任报告者）与 `OptimisticStateOracle`
///      （去信任但有窗口）之间二选一。抽成接口后，同一份验证器与同一份
///      `Settlement` 可以在部署时选择任意一种根来源，不改任何业务逻辑。
interface IFinalizedRootSource {
    /// @notice 该高度是否已有一个**可用**的根，且与给定值一致。
    /// @dev 实现必须 fail-closed：窗口内、未达成、被作废的根一律返回 false。
    function matches(uint256 height, bytes32 root) external view returns (bool);
}
