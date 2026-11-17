// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title 回执验证模块接口
/// @notice 第一版为 3-of-5 多签；第二版可替换为门限签名，第三版可替换为轻客户端或证明验证。
///         替换时不得修改 Settlement 的业务逻辑（`04-接口与状态机规范.md` §2.4）。
interface IAttestationVerifier {
    function verify(bytes32 digest, bytes calldata proof) external view returns (bool);
}
