// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ICanonicalReceiptSource } from "./interfaces/ICanonicalReceiptSource.sol";
import { ReceiptChainDomain } from "./libraries/ReceiptChainDomain.sol";

/// @title Canonical receipt definition registry (source chain)
/// @notice Critical fix from the third external review round (RECEIPT-CANONICALIZATION-001):
///         **The source chain recomputes receiptHash independently and never accepts a prover-submitted value.**
///
///         Key design points:
///         * Receipt context (epoch / orderId / destination chain / sink / asset / amount / recipient / solver)
///           written by the source chain at batch time from **locked orders and market configuration**, not from prover calldata;
///         * Immutable once written (`AlreadySet` rejects duplicate registration), so a prover cannot replace it afterwards;
///         * The encoding of `receiptHashOf` matches the destination-chain `PaymentReceiptSink.receiptHashOf` field for field.
///
/// @dev Why asset must come from here and not from the proof: a balance delta cannot tell a token's economic value.
///      An attacker can deploy a FakeUSDC (balanceOf returns anything, transferFrom always succeeds),
///      and the sink would "think funds arrived". So asset must be a protocol-recognized canonical market asset.
/// @dev Boundary: this contract only **defines** receipts; it does not verify destination-chain state or release funds.
contract CanonicalReceiptRegistry is ICanonicalReceiptSource {
    struct ReceiptContext {
        uint64 epoch;
        uint256 orderId;
        uint64 sourceChainId;
        uint64 targetChainId;
        address solver;
        address recipient;
        address asset;
        uint256 amount;
        address receiptSink;
        bool set;
    }

    /// @notice The authority allowed to register receipt contexts (the Settlement at deploy time, or the operator multisig).
    address public immutable registrar;

    error NotRegistrar();
    error AlreadySet();
    error NotSet();
    error InvalidContext();
    error OrderAlreadyBound();

    /// @notice Reject a second digest attempting to reuse the same order.
    mapping(uint256 => bytes32) public registeredDigestByOrder;

    /// @notice digest -> locked receipt context.
    mapping(bytes32 => ReceiptContext) public contexts;

    event ReceiptContextSet(
        bytes32 indexed digest,
        uint64 indexed epoch,
        uint256 orderId,
        address receiptSink,
        address asset,
        uint256 amount,
        address recipient,
        bytes32 receiptHash
    );

    constructor(address registrar_) {
        // The registrar defines payment business context. An EOA makes this an
        // unreviewable single-key authority, so production wiring must use a
        // contract boundary (Settlement, timelock, or audited multisig).
        if (registrar_ == address(0) || registrar_.code.length == 0) revert InvalidContext();
        registrar = registrar_;
    }

    /// @notice Register the canonical receipt context for a settlement digest. **Registerable only once**.
    /// @dev Parameters must come from locked source-chain state (order-book orders + market configuration), never from a prover.
    function setContext(
        bytes32 digest,
        uint64 epoch,
        uint256 orderId,
        uint64 targetChainId,
        address solver,
        address recipient,
        address asset,
        uint256 amount,
        address receiptSink
    ) external {
        if (msg.sender != registrar) revert NotRegistrar();
        // The receipt hash encodes sourceChainId as uint64; a larger EVM
        // chainid must never silently alias a lower-64-bit chain identity.
        uint64 sourceChain = ReceiptChainDomain.checked(block.chainid);
        ReceiptContext memory next = ReceiptContext({
            epoch: epoch,
            orderId: orderId,
            sourceChainId: sourceChain,
            targetChainId: targetChainId,
            solver: solver,
            recipient: recipient,
            asset: asset,
            amount: amount,
            receiptSink: receiptSink,
            set: true
        });
        _commitContext(digest, next);
    }

    /// @dev Localized validation and write reduce optimizer stack liveness
    ///      without changing the external registrar ABI.
    function _commitContext(bytes32 digest, ReceiptContext memory next) private {
        if (contexts[digest].set) revert AlreadySet();
        if (digest == bytes32(0)) revert InvalidContext();
        if (registeredDigestByOrder[next.orderId] != bytes32(0)) revert OrderAlreadyBound();
        if (
            next.receiptSink == address(0) || next.asset == address(0) || next.recipient == address(0)
                || next.amount == 0 || next.targetChainId == 0 || next.solver == address(0)
        ) revert InvalidContext();
        registeredDigestByOrder[next.orderId] = digest;
        contexts[digest] = next;
        emit ReceiptContextSet(
            digest, next.epoch, next.orderId, next.receiptSink, next.asset, next.amount, next.recipient, _hash(next)
        );
    }

    /// @notice The canonical receipt hash for this digest (recomputed independently by the source chain).
    function receiptHashOf(bytes32 digest) public view returns (bytes32) {
        ReceiptContext memory c = contexts[digest];
        if (!c.set) revert NotSet();
        return _hash(c);
    }

    /// @inheritdoc ICanonicalReceiptSource
    function canonicalReceipt(bytes32 digest)
        external
        view
        override
        returns (
            uint64 targetChainId,
            address receiptSink,
            address asset,
            uint256 amount,
            address recipient,
            bytes32 receiptHash
        )
    {
        ReceiptContext memory c = contexts[digest];
        if (!c.set) revert NotSet();
        return (c.targetChainId, c.receiptSink, c.asset, c.amount, c.recipient, _hash(c));
    }

    /// @dev The encoding must match the destination-chain `PaymentReceiptSink.receiptHashOf` **exactly**.
    function _hash(ReceiptContext memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "BEX_PAYMENT_RECEIPT_V1",
                c.epoch,
                c.orderId,
                c.sourceChainId,
                c.targetChainId,
                c.solver,
                c.recipient,
                c.asset,
                c.amount
            )
        );
    }
}
