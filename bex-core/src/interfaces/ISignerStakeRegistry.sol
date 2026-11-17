// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title 版本化签名者质押登记接口（BEX-21 选项 B）
/// @notice `ChallengeableAttestation` 附加门消费的最小面：
///         纪元快照门限、签名者是否"快照内 + 足额锁定 + 未退出"、质押余额、授权罚没。
///         登记/锁定/退出的完整 API 见 `SignerStakeRegistry` 本体。
interface ISignerStakeRegistry {
    /// @notice 某纪元当前快照的签名门限；无快照时返回 0（调用方据此 fail-closed）。
    function snapshotThreshold(uint64 epoch) external view returns (uint256);
    /// @notice 签名权是否有效：属于当前快照、锁定质押达到快照要求、且未请求退出。
    function isBondedSigner(uint64 epoch, address signer) external view returns (bool);
    /// @notice 某签名者在某纪元的当前锁定质押。
    function stakeOf(uint64 epoch, address signer) external view returns (uint256);
    /// @notice 罚没（仅登记时绑定的唯一 slasher 可调）：按可用质押封顶，返回实际罚没额。
    function slash(uint64 epoch, address signer, uint256 amount, address to) external returns (uint256 slashed);
}
