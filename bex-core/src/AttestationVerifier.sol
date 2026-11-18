// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IAttestationVerifier } from "./interfaces/IAttestationVerifier.sol";
import { ISignerRecovery } from "./interfaces/ISignerRecovery.sol";
import { AttestationParams } from "./libraries/AttestationParams.sol";

/// @title AttestationVerifier
/// @notice Receipt verification module: **deploy-time configurable t-of-n multisig** (default 3-of-5, matching the first version exactly).
/// @dev M2 implementation. The three frozen conventions (see docs/05-M2-interface-freeze-record.md):
///      1. Signing method: sign `digest` after EIP-191 personal_sign wrapping;
///      2. proof format: N 65-byte signatures (r ‖ s ‖ v) concatenated directly, order-independent;
///      3. Duplicate signers, non-signers, non-low-s values, and empty or non-65-multiple lengths are all rejected.
///      The signer set is immutable in the first version; the update mechanism is review item P1-5 and belongs to a later version.
contract AttestationVerifier is IAttestationVerifier, ISignerRecovery {
    /// @notice Threshold (t). **Deploy-time parameter**: `majority(n) ≤ t ≤ n` (`AttestationParams.validate`).
    uint256 public immutable THRESHOLD;
    /// @notice Signer count (n). **Deploy-time parameter**: 1 ≤ n ≤ 15 (`AttestationParams.MAX_SIGNERS`).
    uint256 public immutable SIGNER_COUNT;

    /// @dev Half the secp256k1 curve order, used to reject malleable signatures (s > n/2).
    uint256 private constant SECP256K1N_DIV_2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    error InvalidSignerSet();
    error InvalidProofLength();

    address[] private _signers;
    mapping(address => bool) private _isSigner;

    /// @param signers_ Signer set (dynamic length, 1–15 entries; duplicates or the zero address revert)
    /// @param threshold_ Threshold (strict majority ≤ t ≤ n)
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

    /// @notice Verify receipt signatures.
    /// @dev Validate every provided signature (no early return), then require the count of valid, distinct signatures to reach the threshold.
    function verify(bytes32 digest, bytes calldata proof) external view returns (bool) {
        if (proof.length == 0 || proof.length % 65 != 0) revert InvalidProofLength();

        uint256 n = proof.length / 65;
        if (n < THRESHOLD || n > SIGNER_COUNT) return false;

        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));

        // Size the dedup array by the **actual signer count**, parameterized by SIGNER_COUNT (the old implementation hardcoded 5 slots)
        address[] memory seen = new address[](SIGNER_COUNT);
        uint256 valid = 0;

        for (uint256 i = 0; i < n; i++) {
            (uint8 v, bytes32 r, bytes32 s) = _split(proof, i);
            if (v != 27 && v != 28) return false; // Audit L-1: v must be canonical
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

    /// @notice Recover the set of **valid, distinct** signers in a proof (the attribution entry point for BEX-21 option B).
    /// @dev Same checks as `verify` (canonical v, low s, signer set, dedup), but returns the set itself instead of a boolean:
    ///      Invalid, duplicate, or non-signer signatures are skipped and not counted; an illegal proof length reverts exactly as in `verify`.
    ///      Whether the threshold is met is for the caller to decide — the semantics of `verify` do not change because of this function.
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

    /// @notice Return the address of the i-th signer (only for M1 self-checks and M2 tests).
    function signerAt(uint256 i) external view returns (address) {
        require(i < SIGNER_COUNT, "index out of range");
        return _signers[i];
    }

    /// @notice Whether an address is a signer.
    function isSigner(address account) external view returns (bool) {
        return _isSigner[account];
    }

    /// @dev Extract the i-th signature segment from the concatenated proof.
    function _split(bytes calldata proof, uint256 i) private pure returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 offset = i * 65;
        assembly {
            r := calldataload(add(proof.offset, offset))
            s := calldataload(add(proof.offset, add(offset, 32)))
            v := byte(0, calldataload(add(proof.offset, add(offset, 64))))
        }
    }
}
