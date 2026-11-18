// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { BatchSettlement } from "../types/BexTypes.sol";

/// @title Match-validity verifier interface (implemented per tier)
/// @notice The first version has only a plaintext-tier implementation (`PlaintextMatchVerifier`); the sealed and encrypted tiers each add their own implementation,
///         with no changes to `Settlement`'s business logic. This mirrors the extension pattern of `IAttestationVerifier`:
///         a receipt proves "the solver has paid on the destination chain", while `matchProof` proves "this batch's match is valid" — neither substitutes for the other.
/// @dev See `docs/09-tier-reserved-interface-spec.md` §3. The interface only returns `volume`: the only match output the settlement layer really needs
///      is "how much base traded" (for bookkeeping conservation); prices and allocation details stay inside the matching layer and never cross the boundary.
interface IMatchVerifier {
    /// @notice Validate this batch's match result. Failure must revert (never return false).
    /// @param batch  Settlement payload
    /// @param matchProof Validity proof for this tier:
    ///        Plaintext tier -> empty bytes (validity comes from the recomputation itself)
    ///        Sealed tier -> threshold decryption certificate / reveal proof
    ///        Encrypted tier -> decryption correctness proof or zkFHE proof
    /// @return volume Amount of base traded in this batch, for the settlement layer's bookkeeping-conservation check
    function verifyMatch(BatchSettlement calldata batch, bytes calldata matchProof)
        external
        view
        returns (uint256 volume);
}
