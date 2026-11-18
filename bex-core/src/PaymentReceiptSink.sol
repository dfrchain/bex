// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";
import { SafeTransfer } from "./libraries/SafeTransfer.sol";
import { ReceiptChainDomain } from "./libraries/ReceiptChainDomain.sol";

/// @title Destination-chain payment receipt sink
/// @notice Fixes a **real funds-semantics bug** (external review, 2026-10-06, round 2, Critical severity):
///         The original implementation used "recipient balance ≥ amount due" as the credential for the source chain to release funds.
///         But a balance proves no payment — a user's balance may come from money they already had, third-party transfers,
///         other protocol income, or the sum of several transfers. **"This address is well funded" ≠ "the solver paid for this order"**.
///
///         This contract creates a **protocol-specific, unique, provable** payment receipt:
///         the solver pays through this contract (instead of a direct ERC-20 transfer), and the contract writes
///         `paid[receiptHash] = 1` after a successful payment; the source chain proves this storage slot, not a balance.
///
/// @dev A receipt binds the full business context (orderId / epoch / source chain / destination chain / solver / recipient /
///      asset / amount); any difference in any field yields a different receiptHash,
///      so there is no room for "order A's payment impersonating order B".
/// @dev Idempotent: the same receiptHash can only settle once (a repeat payment reverts), so retries cannot double-book.
contract PaymentReceiptSink {
    using SafeTransfer for IERC20;

    /// @dev Reentrancy lock: `pay` reads back the recipient's balance after the transfer to verify the received amount, and the transfer
    ///      makes an external call to an external token. Lock the whole function so a malicious/callback token cannot reenter `pay` during `safeTransferFrom`
    ///      and disturb the before/after difference check.
    uint256 private _reentrancyLock = 1;

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert Reentrant();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    /// @notice Protocol-recognized destination-chain settlement assets (third review round, item 5: assets must be canonical).
    /// @dev Why it must exist: a `before/after` difference cannot tell a token's economic value.
    ///      An attacker can deploy a FakeUSDC (`balanceOf` returns anything, `transferFrom` always succeeds),
    ///      and the sink would "think funds arrived". So `pay()` only accepts assets **on the allowlist**.
    ///      By design this is an immutable set (fixed at deploy time) with no interface to add to the allowlist —
    ///      shrinking the admin permission surface; to extend it, redeploy the sink and update the source-chain canonical configuration.
    mapping(address => bool) public allowedAsset;

    /// @notice Completed payment receipts: receiptHash -> 1 means paid.
    /// @dev Source-chain storage proofs read this slot directly, so the **slot layout is part of the cross-chain interface**
    ///      and must not be changed casually (any change must also update the verifier's slot derivation).
    mapping(bytes32 => uint256) public paid;

    error AlreadyPaid(bytes32 receiptHash);
    error ZeroAmount();
    error ZeroRecipient();
    error AmountMismatch();
    error Reentrant();
    error AssetNotAllowed(address asset);

    /// @param allowedAssets_ Canonical asset allowlist fixed at deploy time (must not be empty or contain the zero address)
    constructor(address[] memory allowedAssets_) {
        if (allowedAssets_.length == 0) revert AssetNotAllowed(address(0));
        for (uint256 i = 0; i < allowedAssets_.length; i++) {
            address a = allowedAssets_[i];
            // Fail closed at deployment: a mistaken EOA/undeployed token can never
            // satisfy a canonical ERC-20 payment receipt on this immutable sink.
            if (a.code.length == 0) revert AssetNotAllowed(a);
            allowedAsset[a] = true;
        }
    }

    event PaymentReceipted(
        bytes32 indexed receiptHash,
        uint256 indexed epoch,
        uint256 indexed orderId,
        uint64 sourceChainId,
        address solver,
        address recipient,
        address asset,
        uint256 amount
    );

    /// @notice Compute the receipt hash. Off-chain and on-chain code must use **exactly the same encoding**.
    function receiptHashOf(
        uint256 epoch,
        uint256 orderId,
        uint64 sourceChainId,
        uint64 targetChainId,
        address solver,
        address recipient,
        address asset,
        uint256 amount
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "BEX_PAYMENT_RECEIPT_V1", epoch, orderId, sourceChainId, targetChainId, solver, recipient, asset, amount
            )
        );
    }

    /// @notice The solver pays the recipient through this contract and writes a receipt.
    /// @dev The amount is the **actual amount received**: record before/after, confirm the difference equals amount,
    ///      blocking malformed tokens that "return true but transfer nothing" (same discipline as OrderBook's deposit check).
    function pay(uint256 epoch, uint256 orderId, uint64 sourceChainId, address recipient, address asset, uint256 amount)
        external
        nonReentrant
        returns (bytes32 receiptHash)
    {
        // Encoding targetChainId as uint64 without this guard could permit
        // cross-chain receipt-domain collisions for oversized EVM chain IDs.
        // Reject before state mutation or external asset transfers.
        uint64 targetChainId = ReceiptChainDomain.checked(block.chainid);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroRecipient();
        if (!allowedAsset[asset]) revert AssetNotAllowed(asset);

        receiptHash = receiptHashOf(epoch, orderId, sourceChainId, targetChainId, msg.sender, recipient, asset, amount);
        if (paid[receiptHash] != 0) revert AlreadyPaid(receiptHash);

        // Write receipt state first (CEI), then transfer; a failed transfer reverts the whole transaction
        paid[receiptHash] = 1;

        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(recipient);
        token.safeTransferFrom(msg.sender, recipient, amount);
        if (token.balanceOf(recipient) - before != amount) revert AmountMismatch();

        emit PaymentReceipted(receiptHash, epoch, orderId, sourceChainId, msg.sender, recipient, asset, amount);
    }

    /// @notice Read-only query for whether a receipt has been paid.
    function isPaid(bytes32 receiptHash) external view returns (bool) {
        return paid[receiptHash] != 0;
    }
}
