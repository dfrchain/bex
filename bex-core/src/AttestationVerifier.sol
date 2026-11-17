// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IAttestationVerifier } from "./interfaces/IAttestationVerifier.sol";
import { ISignerRecovery } from "./interfaces/ISignerRecovery.sol";
import { AttestationParams } from "./libraries/AttestationParams.sol";

/// @title AttestationVerifier
/// @notice 回执验证模块：**部署期可配的 t-of-n 多签**（默认 3-of-5，与第一版逐位一致）。
/// @dev M2 实现。已钉死的三个约定（见 docs/05-M2接口钉死记录.md）：
///      1. 签名方式：对 `digest` 做 EIP-191 personal_sign 后签名；
///      2. proof 格式：N 段 65 字节签名（r ‖ s ‖ v）直接拼接，顺序无关；
///      3. 重复签名者、非签名者、非低 s 值、空或长度非 65 倍数，一律拒绝。
///      签名者集合在第一版不可变更；更新机制见评审 P1-5，属于后续版本。
contract AttestationVerifier is IAttestationVerifier, ISignerRecovery {
    /// @notice 门限（t）。**部署期参数**：`majority(n) ≤ t ≤ n`（`AttestationParams.validate`）。
    uint256 public immutable THRESHOLD;
    /// @notice 签名者人数（n）。**部署期参数**：1 ≤ n ≤ 15（`AttestationParams.MAX_SIGNERS`）。
    uint256 public immutable SIGNER_COUNT;

    /// @dev secp256k1 曲线阶的一半，用于拒绝可延展签名（s > n/2）。
    uint256 private constant SECP256K1N_DIV_2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    error InvalidSignerSet();
    error InvalidProofLength();

    address[] private _signers;
    mapping(address => bool) private _isSigner;

    /// @param signers_ 签名者集合（动态长度，1–15 个；重复或零地址即 revert）
    /// @param threshold_ 门限（严格多数 ≤ t ≤ n）
    constructor(address[] memory signers_, uint256 threshold_) {
        uint256 n = signers_.length;
        AttestationParams.validate(n, threshold_);
        SIGNER_COUNT = n;
        THRESHOLD = threshold_;
        _signers = signers_;
        for (uint256 i = 0; i < n; i++) {
            address s = signers_[i];
            if (s == address(0) || _isSigner[s]) revert InvalidSignerSet();
            _isSigner[s] = true;
        }
    }

    /// @notice 验证回执签名。
    /// @dev 校验全部提供的签名（不提前返回），再要求有效且互不相同的签名数达到阈值。
    function verify(bytes32 digest, bytes calldata proof) external view returns (bool) {
        if (proof.length == 0 || proof.length % 65 != 0) revert InvalidProofLength();

        uint256 n = proof.length / 65;
        if (n < THRESHOLD || n > SIGNER_COUNT) return false;

        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));

        // 去重数组按**实际人数**开，随 SIGNER_COUNT 参数化（旧实现写死 5 个槽位）
        address[] memory seen = new address[](SIGNER_COUNT);
        uint256 valid = 0;

        for (uint256 i = 0; i < n; i++) {
            (uint8 v, bytes32 r, bytes32 s) = _split(proof, i);
            if (v != 27 && v != 28) return false; // 审计 L-1：v 必须规范
            if (uint256(s) > SECP256K1N_DIV_2) return false;

            address signer = ecrecover(signedHash, v, r, s);
            if (signer == address(0) || !_isSigner[signer]) return false;

            for (uint256 j = 0; j < valid; j++) {
                if (seen[j] == signer) return false;
            }
            seen[valid] = signer;
            valid++;
        }

        return valid >= THRESHOLD;
    }

    /// @notice 恢复 proof 中**有效且互不相同**的签名者集合（BEX-21 选项 B 的归因入口）。
    /// @dev 与 `verify` 同一套校验（v 规范、低 s、签名者集、去重），但返回集合本身而非布尔：
    ///      无效、重复或非签名者的签名被跳过、不计入；proof 长度非法与 `verify` 一致 revert。
    ///      是否达到门限由调用方判断——`verify` 的语义不因此函数而改变。
    function recoverValidSigners(bytes32 digest, bytes calldata proof) external view returns (address[] memory) {
        if (proof.length == 0 || proof.length % 65 != 0) revert InvalidProofLength();

        uint256 n = proof.length / 65;
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));

        address[] memory seen = new address[](SIGNER_COUNT);
        uint256 valid = 0;

        for (uint256 i = 0; i < n; i++) {
            (uint8 v, bytes32 r, bytes32 s) = _split(proof, i);
            if (v != 27 && v != 28) continue;
            if (uint256(s) > SECP256K1N_DIV_2) continue;

            address signer = ecrecover(signedHash, v, r, s);
            if (signer == address(0) || !_isSigner[signer]) continue;

            bool dup = false;
            for (uint256 j = 0; j < valid; j++) {
                if (seen[j] == signer) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            seen[valid] = signer;
            valid++;
        }

        address[] memory out = new address[](valid);
        for (uint256 i = 0; i < valid; i++) {
            out[i] = seen[i];
        }
        return out;
    }

    /// @notice 返回第 i 个签名者地址（仅用于 M1 自检与 M2 测试）。
    function signerAt(uint256 i) external view returns (address) {
        require(i < SIGNER_COUNT, "index out of range");
        return _signers[i];
    }

    /// @notice 某地址是否为签名者。
    function isSigner(address account) external view returns (bool) {
        return _isSigner[account];
    }

    /// @dev 从拼接的 proof 中取出第 i 段签名。
    function _split(bytes calldata proof, uint256 i) private pure returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 offset = i * 65;
        assembly {
            r := calldataload(add(proof.offset, offset))
            s := calldataload(add(proof.offset, add(offset, 32)))
            v := byte(0, calldataload(add(proof.offset, add(offset, 64))))
        }
    }
}
