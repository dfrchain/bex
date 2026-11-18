// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Order } from "../types/BexTypes.sol";

/// @title Order-book interface the settlement layer needs (minimal surface)
/// @notice `Settlement` depends on only these 5 methods: close status, refund deadline height, set commitment, refund entry point, and bulk posting.
///         The plaintext tier (`OrderBook`) and the sealed tier (`SealedOrderBook`) can therefore share one settlement contract,
///         and the settlement layer never reads any order contents.
/// @dev Why the dependency moved from a concrete contract to an interface: the sealed tier's order book stores only commitments/ciphertext and cannot reuse `OrderBook`'s
///      plaintext storage; if `Settlement` kept depending on a concrete type, the settlement layer would have to change to plug it in.
///      This interface confines the change to the **dependency type**; `Settlement`'s check order and control flow are untouched (see `docs/05` §40).
interface IOrderBook {
    /// @notice Whether a batch has been closed.
    function isSealed(uint64 epoch) external view returns (bool);

    /// @notice Receipt submission deadline height; past it, users can reclaim their funds.
    function epochDeadlineBlock(uint64 epoch) external view returns (uint256);

    /// @notice Order-set commitment stored at close.
    function orderSetHashOf(uint64 epoch) external view returns (bytes32);

    /// @notice Settlement-triggered refund. Settlement contract only.
    /// @dev Settlement forwards the original external caller so an arbitrary third party cannot force a refund.
    function refundOnSettlement(bytes32 orderId, address requester) external;

    /// @notice Bulk posting: transfer traded amounts to the solver and refund the remainder to users.
    function settleBatch(bytes32[] calldata orderIds, uint256[] calldata amountSolds, address solver) external;

    /// @notice Whether this tier's closed set provides **plaintext order validity** (the data source for tier-independent deadline checks).
    /// @dev Plaintext tier: `true` (contents are plaintext on-chain, so `Settlement` can check `validUntil` per order);
    ///      Sealed tier: `false` (validity is **ciphertext content**; only the commitment is on-chain — enforced by that tier's verifier at reveal,
    ///      see the check on `opening.validUntil` in `SealedMatchVerifier`).
    ///      This **must be declared explicitly**: silently returning an empty set would make the "settlement window / validity" checks quietly disappear.
    function exposesPlaintextValidity() external view returns (bool);

    /// @notice Only usable when `exposesPlaintextValidity() == true`: the plaintext order contents of this batch's closed set.
    /// @dev Tiers without plaintext revert on this method (instead of returning an empty array), so callers never mistake it for "no expired orders".
    function epochOrderContents(uint64 epoch) external view returns (Order[] memory orders);
}
