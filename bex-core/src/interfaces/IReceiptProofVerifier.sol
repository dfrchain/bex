// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IAttestationVerifier } from "./IAttestationVerifier.sol";

/// @title G-2/G-3 回执证明验证器接口
/// @notice 与 `IAttestationVerifier` 同一个插槽（`Settlement.settle` 只调用 `verify`），
///         但额外暴露两个**只读元信息**，让监控与审计能直接看清"这条链靠什么根、用哪种证明"：
///         `proofKind()`（证明系统）与 `rootSource()`（根从哪来）。
/// @dev 为什么现在就把接口冻结：G-1 换 `IAttestationVerifier` 已经验证过"不改 Settlement 就能换验证器"
///      （见 `docs/33`）；G-2 只要满足同一个函数签名即可原地替换。冻结接口的代价很低，
///      而等到实现时才定接口，会强迫结算层返工。
/// @dev 边界（`docs/34` §二）：接口本身不保证任何安全性——D1（可信根）/D2（证明路径）/
///      D3（语义可判定）/D4（失败模式 fail-closed）必须在目标链上逐条确认。
interface IReceiptProofVerifier is IAttestationVerifier {
    /// @notice 证明系统标识：1=多签（G-1）、2=MPT 状态证明、3=zkVM/zk 证明，其余留给未来。
    function proofKind() external view returns (uint8);

    /// @notice 根的来源描述（例如 "L1 finalized stateRoot" / "OP output root via L1 contract"）。
    /// @dev 返回 bytes32 只是给链上/链下对齐用的标签，真正的语义写在部署文档与 `docs/34` 里。
    function rootSource() external view returns (bytes32);

    /// @notice 该证明系统要求的最小挑战窗口（区块）。挑战窗口必须 ≥ 它，否则证明来不及构造。
    function minChallengeWindowBlocks() external view returns (uint256);
}
