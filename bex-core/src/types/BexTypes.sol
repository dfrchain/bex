// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title BEX layer-1 shared types
/// @notice Field order strictly matches `06-data-encoding-and-hashing-spec.md` and `04-interface-and-state-machine-spec.md`;
///         any change alters orderHash and settlementDigest, so the version must be bumped together.

/// @notice User order. Field order is the ABI encoding order of orderHash; do not change it.
struct Order {
    address trader;
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 minBuyAmount;
    uint64 epoch;
    uint64 validUntil;
    bool partiallyFillable;
    uint256 nonce;
}

/// @notice Sealed-tier order (commitment-based): on-chain stores **only the commitment and the amount upper bound**; order contents (price, quantity, direction)
///         stay in an envelope encrypted on the user's device, decrypted after close by the threshold committee, which issues a reveal certificate.
/// @dev The difference from `Order` is exactly the sealed tier's leakage surface (see `docs/23` §3.3):
///      - Visible on-chain: trader, sellToken, buyToken, maxSellAmount (upper bound), commitment, ciphertextHash, epoch;
///      - Not visible on-chain: limit price, true quantity (only ≤ maxSellAmount can be inferred), intent beyond direction, salt.
/// @dev **Storage packing (optimized 2026-09-26)**: field order is arranged to "pack slots wherever possible" —
///      `trader(20) + epoch(8)` share a slot, `maxSellAmount` uses uint120 (same bound as `MAX_ORDER_VALUE`),
///      and the whole struct takes **7 slots**. Settling a full 200-order batch reads each order once, so the 1 cold SLOAD saved per order is ≈ 420K gas (measured; see `test/GasReportSealed.t.sol`).
///      Changing field order or types changes orderId (orderId ABI-encodes the public fields), so the version must be bumped together.
struct SealedOrder {
    address trader;
    /// @dev Shares a slot with trader (20+8=28 bytes).
    uint64 epoch;
    address sellToken;
    address buyToken;
    /// @dev Amount upper bound, also the locked amount; capped at `MAX_ORDER_VALUE = type(uint120).max`.
    ///      At settlement it is released per the revealed true volume, with the remainder refunded to the user.
    uint120 maxSellAmount;
    /// @dev Order content commitment: `keccak(contents ‖ salt)`; the salt exists only between the user and the committee.
    bytes32 commitment;
    /// @dev Hash of the encrypted envelope (a data-availability pointer); the committee uses it to fetch the ciphertext.
    bytes32 ciphertextHash;
    uint256 nonce;
}

/// @notice Order contents after a sealed-tier **reveal** (unboxing): submitted on-chain after close together with the reveal certificate.
/// @dev The on-chain enforcement point of the commitment-based order book: `commitment` must equal this struct (salt included), recomputed via
///      `SealedOrderLib.commitmentOf`, so the committee cannot swap the user's commitment for different contents.
///      Field order is frozen in `docs/05` §40; any change alters commitment values and requires a version bump.
struct SealedOpening {
    bytes32 orderId;
    address trader;
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 minBuyAmount;
    uint64 validUntil;
    bool partiallyFillable;
    uint256 nonce;
    bytes32 salt;
}

/// @notice Single fill details.
struct Fill {
    bytes32 orderId;
    uint256 amountSold;
    uint256 amountReceived;
}

/// @notice Settlement payload.
/// @dev Frozen per `docs/05-M2-interface-freeze-record.md` §5:
///      - `orderIds` must be **all closed orders of this batch** (including unfilled ones), in ascending `(limit, orderId)` order;
///      - `submissionIndices[i]` is the index of `orderIds[i]` in `OrderBook`'s submission order;
///      - The contract checks `epochOrderIdAt(epoch, idx) == orderIds[i]` against this, and uses a 256-bit bitmap
///        to prove the payload covers exactly `0..N-1`, completing the set-integrity check without sorting or trusting the matcher.
struct BatchSettlement {
    uint64 epoch;
    uint256 chainId;
    bytes32 pairHash;
    /// @dev Trading-pair definition. On-chain recomputation needs base/quote to determine order direction:
    ///      sellToken == baseToken is a sell order (ask), otherwise a buy order (bid).
    ///      `pairHash` must equal `keccak256(abi.encode(baseToken, quoteToken))` (see docs/05 §7).
    address baseToken;
    address quoteToken;
    uint256 priceNum;
    uint256 priceDen;
    /// @dev Final traded volume (in base units). The rounding-feasibility fallback may push it below the maximum recomputed by `_scan`,
    ///      so it must be declared explicitly by the payload and included in the digest: on-chain checks `volume ≤ _scan recomputed value` and the allocation invariants,
    ///      while "whether it is the maximum feasible value" is verified off-chain by the 3-of-5 verifiers (see docs/05 §11, Option B).
    uint256 volume;
    bytes32 orderSetHash;
    bytes32 matcherVersion;
    uint64 deadline;
    address solver;
    bytes32[] orderIds;
    uint32[] submissionIndices;
    Fill[] fills;
}

/// @notice Order state machine. The value order must match the transition table in `04-interface-and-state-machine-spec.md` §3.
enum OrderState {
    NONE,
    SUBMITTED,
    LOCKED,
    AUCTIONED,
    AWARDED,
    FILLED,
    ATTESTED,
    SETTLED,
    REFUNDED,
    CANCELLED
}
