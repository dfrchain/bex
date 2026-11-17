// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title 签名者归因接口（BEX-21 选项 B）
/// @notice 在 `IAttestationVerifier.verify` 的布尔语义之外，确定性恢复一份 proof 中
///         **有效且互不相同**的签名者子集——罚没归因（决策包 §4.3）的前提。
///         是否达到门限由调用方判断；本接口不改变 `verify` 的任何语义。
interface ISignerRecovery {
    function recoverValidSigners(bytes32 digest, bytes calldata proof) external view returns (address[] memory);
}
