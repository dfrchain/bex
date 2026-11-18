// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Canonical payment receipt definition source
/// @notice Critical fix from the third external review round (RECEIPT-CANONICALIZATION-001):
///         **The source chain must recompute receiptHash itself and must not trust a prover-submitted value.**
///
///         Otherwise an attacker can fabricate a receipt in their own favor (e.g. asset=FakeToken, amount=1),
///         and get `paid[fakeHash] = 1` on the destination chain, then combine it with a real order's digest.
///         At that point "receiptHash binds many fields" is meaningless for security — it only binds fields the attacker chose.
///
/// @dev The authoritative source must derive only from **locked source-chain state** (orders in the order book, batch configuration, market registry)
///      and must accept no input from any prover.
interface ICanonicalReceiptSource {
    /// @notice For a given settlement digest, return the canonical receipt definition recognized by the source chain.
    /// @param digest Settlement digest (already bound to source-chain state: epoch / batch / solver, etc.)
    /// @return targetChainId Destination chain ID (from market/order configuration, not from the proof)
    /// @return receiptSink The protocol-recognized receipt contract on the destination chain (a configuration item, not from the proof)
    /// @return asset Destination-chain settlement asset (must be a canonical market asset, not self-reported by the proof)
    /// @return amount Amount due (from order/batch computation, not self-reported by the proof)
    /// @return recipient Recipient (from the order, not self-reported by the proof)
    /// @return receiptHash Canonical receipt hash computed independently by the source chain
    function canonicalReceipt(bytes32 digest)
        external
        view
        returns (
            uint64 targetChainId,
            address receiptSink,
            address asset,
            uint256 amount,
            address recipient,
            bytes32 receiptHash
        );
}
