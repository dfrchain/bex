// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";
import { IOrderBook } from "./interfaces/IOrderBook.sol";
import { Errors } from "./libraries/Errors.sol";
import { OrderLib } from "./libraries/OrderLib.sol";
import { MatchParams } from "./libraries/Params.sol";
import { SafeTransfer } from "./libraries/SafeTransfer.sol";
import { Order, OrderState } from "./types/BexTypes.sol";

/// @title OrderBook
/// @notice Receive and validate signed orders, lock user funds, archive them by batch, and produce an order-set commitment when the batch closes.
/// @dev Key design (see docs/05):
///      - Orders are stored in **submission order**; the close commitment `keccak(concat(ids))` is computed by the contract itself — no sorting, no trust in off-chain data;
///      - Completeness is checked on the settlement side with "submission index + bitmap";
///      - Expiry reclaim and settlement are mutually exclusive paths (guaranteed by the state machine);
///      - Batch and order parameters are **deploy-time parameters** (`MatchParams.Config`, with bounds and cross-invariants),
///        with the first version's decided values unchanged; parameter registration is in `docs/31-parameter-tier-registry-(draft).md`.
contract OrderBook is IOrderBook {
    using SafeTransfer for IERC20;

    /// @notice Batch length (source-chain blocks). Deploy-time parameter; first version's decided value is 30 (`spec/09`).
    uint256 public immutable EPOCH_BLOCKS;
    /// @notice Per-batch order cap. Deploy-time parameter; first version's decided value is 200.
    uint256 public immutable MAX_ORDERS_PER_EPOCH;
    /// @notice Per-order field upper bound. Deploy-time parameter; first version's decided value is 2^120−1 (the `uint120` field cap).
    uint256 public immutable MAX_ORDER_VALUE;
    /// @notice How many batches past the placement batch an order's validity may extend. Deploy-time parameter; first version's decided value is 10.
    uint64 public immutable MAX_VALIDITY_EPOCHS;

    /// @notice Signature domain separator, binding the domain name, version, chain ID, and contract address.
    bytes32 public immutable DOMAIN_SEPARATOR;
    /// @notice Number of blocks after the batch boundary during which receipts may still be submitted (the 45-minute equivalent is set per chain by the deployer).
    uint256 public immutable REFUND_DELAY_BLOCKS;
    /// @notice Deployer: used only to bind the settlement contract once.
    address public immutable deployer;
    /// @notice Settlement contract address; immutable once bound.
    address public settlement;

    mapping(bytes32 => uint8) private _orderState;
    mapping(uint64 => bytes32[]) private _epochOrders;
    /// @dev The matchable set fixed at close: cancelled orders removed, submission order preserved.
    mapping(uint64 => bytes32[]) private _sealedOrders;
    mapping(uint64 => bytes32) private _orderSetHash;
    mapping(uint64 => bool) private _sealed;
    mapping(address => mapping(uint256 => bool)) private _nonceUsed;
    mapping(bytes32 => Order) private _orders;
    mapping(bytes32 => uint64) private _orderEpoch;
    mapping(bytes32 => uint256) private _orderLocked;

    /// @notice Token allowlist switch (RT-31 / red-team round 3, R3-01): when on, only operator-vetted tokens are admitted.
    /// @dev Why this must sit at the **order-book entry point**: short-paying / rebasing tokens make `_transferExact`
    ///      revert permanently in `claimExpired`/`cancelOrder`, locking user principal with no emergency withdrawal path.
    ///      An allowlist only on the auction registry does not cover the plaintext tier (`PlaintextMatchVerifier` never reads the registry).
    bool public tokenAdmissionRequired;
    mapping(address => bool) public tokenAllowed;

    uint256 private _reentrancyLock = 1;

    /// @notice BEX-16: actual block height when an epoch's order set was frozen.
    /// @dev Append storage after existing fields to preserve historical slot positions.
    ///      An unsealed epoch reads zero; epochEndBlock is only a schedule, not a seal receipt.
    mapping(uint64 => uint256) public sealedAtBlock;

    event TokenAdmissionRequiredSet(bool required);
    event TokenAllowedSet(address indexed token, bool allowed);

    event OrderSubmitted(
        bytes32 indexed orderId,
        address indexed trader,
        uint64 indexed epoch,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount
    );
    event OrderCancelled(bytes32 indexed orderId, uint256 refunded);
    event OrderRefunded(bytes32 indexed orderId, address indexed trader, uint256 refunded);
    event EpochSealed(uint64 indexed epoch, bytes32 orderSetHash, uint256 orderCount);
    event OrderSettled(bytes32 indexed orderId, address indexed solver, uint256 released, uint256 refunded);
    event SettlementBound(address indexed settlement);

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert Errors.Reentrant();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    /// @notice Deploy-time parameter validation and storage (out-of-range values revert at construction, see `MatchParams.validate`).
    constructor(MatchParams.Config memory params_) {
        MatchParams.validate(params_);
        EPOCH_BLOCKS = params_.epochBlocks;
        MAX_ORDERS_PER_EPOCH = params_.maxOrdersPerEpoch;
        MAX_ORDER_VALUE = params_.maxOrderValue;
        MAX_VALIDITY_EPOCHS = params_.maxValidityEpochs;
        REFUND_DELAY_BLOCKS = params_.refundDelayBlocks;
        DOMAIN_SEPARATOR = OrderLib.domainSeparator(block.chainid, address(this));
        deployer = msg.sender;
    }

    /// @notice The currently active deploy-time parameters. Operators, monitors, and reviewers read them here instead of hardcoding values off-chain (docs/31 §10-5).
    function params() external view returns (MatchParams.Config memory) {
        return MatchParams.Config({
            epochBlocks: EPOCH_BLOCKS,
            maxOrdersPerEpoch: MAX_ORDERS_PER_EPOCH,
            maxOrderValue: MAX_ORDER_VALUE,
            maxValidityEpochs: MAX_VALIDITY_EPOCHS,
            refundDelayBlocks: REFUND_DELAY_BLOCKS
        });
    }

    /// @notice Bind the settlement contract once. Only the deployer may call it, and only once.
    /// @dev This design introduces no upgradeable proxy: once bound, the settlement address is fixed forever, shrinking the permission surface.
    function bindSettlement(address settlement_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (settlement != address(0)) revert Errors.AlreadySet();
        if (settlement_ == address(0)) revert Errors.InvalidOrder();
        settlement = settlement_;
        emit SettlementBound(settlement_);
    }

    // ------------------------------------------------------------ Token allowlist (RT-31)

    /// @notice Toggle "orders must hit the token allowlist". Deployer (operator) only.
    function setTokenAdmissionRequired(bool required) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        tokenAdmissionRequired = required;
        emit TokenAdmissionRequiredSet(required);
    }

    /// @notice Register / delist a tradable token. Deployer only; delisting affects only **later** orders.
    /// @dev Operator vetting criteria (at minimum): no transfer fees, non-rebasing, no transfer switch, no blacklist mechanism.
    ///      These properties cannot be judged automatically on-chain, so this only records the "allowlist fact"; detection is left to the operator and monitoring.
    function setTokenAllowed(address token, bool allowed) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (token == address(0)) revert Errors.InvalidOrder();
        tokenAllowed[token] = allowed;
        emit TokenAllowedSet(token, allowed);
    }

    modifier onlySettlement() {
        if (msg.sender != settlement) revert Errors.NotSettlement();
        _;
    }

    // ------------------------------------------------------------ Batch clock

    /// @notice Current batch number = source-chain height / batch length (rounded down).
    function currentEpoch() public view returns (uint64) {
        // EPOCH_BLOCKS >= 3; truncating a uint64 would need at least 2^64 x 3 blocks, far beyond any chain's reachable lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.number / EPOCH_BLOCKS);
    }

    /// @notice Batch start height (inclusive).
    function epochStartBlock(uint64 epoch) public view returns (uint256) {
        return uint256(epoch) * EPOCH_BLOCKS;
    }

    /// @notice Batch end height (exclusive). The batch can be closed once this height is reached.
    function epochEndBlock(uint64 epoch) public view returns (uint256) {
        return uint256(epoch + 1) * EPOCH_BLOCKS;
    }

    /// @notice Receipt submission deadline height (source-chain view). Past this height, users can reclaim their funds.
    function epochDeadlineBlock(uint64 epoch) public view override returns (uint256) {
        return epochEndBlock(epoch) + REFUND_DELAY_BLOCKS;
    }

    // ------------------------------------------------------------ Queries

    /// @notice Order hash (for client signing and third-party recomputation).
    function orderHashOf(Order calldata order) external view returns (bytes32) {
        return OrderLib.orderHash(DOMAIN_SEPARATOR, order);
    }

    /// @notice Query an order's contents.
    function orderOf(bytes32 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice Query an order's state, returning the uint8 value of `OrderState`.
    function orderState(bytes32 orderId) external view returns (uint8) {
        return _orderState[orderId];
    }

    /// @notice Query a batch's order set (submission order; after close, the set with cancelled orders removed).
    function epochOrders(uint64 epoch) external view returns (bytes32[] memory) {
        if (_sealed[epoch]) return _sealedOrders[epoch];
        return _epochOrders[epoch];
    }

    /// @notice Number of orders in a batch (after close, the count with cancelled orders removed).
    function epochOrderCount(uint64 epoch) external view returns (uint256) {
        if (_sealed[epoch]) return _sealedOrders[epoch].length;
        return _epochOrders[epoch].length;
    }

    /// @notice Get the ID of the i-th order in a batch's **submission order** (after close, based on the set with cancelled orders removed).
    function epochOrderIdAt(uint64 epoch, uint256 index) external view returns (bytes32) {
        if (_sealed[epoch]) return _sealedOrders[epoch][index];
        return _epochOrders[epoch][index];
    }

    /// @notice Fetch **in bulk** all order IDs of a batch (submission order). Lets the settlement contract fetch them in one call instead of one external call per order.
    /// @dev Measured gas (N=200): per-order `epochOrderIdAt` + `orderOf` totals about 3.9M gas,
    ///      dropping to about 0.3M with two bulk calls to this function + `ordersOf` (see docs/05 §19).
    function epochOrderIds(uint64 epoch) external view returns (bytes32[] memory ids) {
        bytes32[] storage source = _sealed[epoch] ? _sealedOrders[epoch] : _epochOrders[epoch];
        uint256 n = source.length;
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = source[i];
        }
    }

    /// @notice Fetch **in bulk** all order contents of a batch, in the same order as `epochOrderIds`.
    function epochOrderContents(uint64 epoch) external view returns (Order[] memory orders) {
        bytes32[] storage source = _sealed[epoch] ? _sealedOrders[epoch] : _epochOrders[epoch];
        uint256 n = source.length;
        orders = new Order[](n);
        for (uint256 i = 0; i < n; i++) {
            orders[i] = _orders[source[i]];
        }
    }

    /// @notice The stored order-set commitment (submission order).
    function orderSetHashOf(uint64 epoch) external view override returns (bytes32) {
        return _orderSetHash[epoch];
    }

    /// @notice The plaintext tier provides plaintext validity: `Settlement` can therefore check `validUntil` per order (tier-independent deadline checks).
    function exposesPlaintextValidity() external pure returns (bool) {
        return true;
    }

    /// @notice Whether a batch has been closed.
    function isSealed(uint64 epoch) external view override returns (bool) {
        return _sealed[epoch];
    }

    // ------------------------------------------------------------ Submit and cancel

    /// @notice Submit an order and lock funds.
    function submitOrder(Order calldata order, bytes calldata signature)
        external
        nonReentrant
        returns (bytes32 orderId)
    {
        // Structural guards
        if (order.trader == address(0)) revert Errors.InvalidOrder();
        if (order.sellToken == address(0) || order.buyToken == address(0)) revert Errors.InvalidOrder();
        if (order.sellToken == order.buyToken) revert Errors.InvalidOrder();
        if (order.sellAmount == 0 || order.minBuyAmount == 0) revert Errors.InvalidOrder();
        if (order.sellAmount > MAX_ORDER_VALUE || order.minBuyAmount > MAX_ORDER_VALUE) revert Errors.InvalidOrder();
        // RT-31 (red-team round 3, R3-01): the token allowlist gate sits at the **entry point**, not only on the auction registry.
        // The buy side must pass too — at settlement, buyToken is paid to this trader, and a bad token would equally revert the payout path.
        if (tokenAdmissionRequired && (!tokenAllowed[order.sellToken] || !tokenAllowed[order.buyToken])) {
            revert Errors.TokenNotAllowed();
        }
        // Audit L-2: `partiallyFillable=false` (all-or-nothing) has no implemented semantics in the first version,
        // so to avoid "the user signed an intent that never takes effect", it is **explicitly rejected** here instead of silently partially filling.
        // Re-enable it once the semantics are implemented (on-chain + off-chain engine + spec), see docs/17 L-2.
        if (!order.partiallyFillable) revert Errors.InvalidOrder();
        // The sell asset must be a contract (otherwise transferFrom on an EOA "silently succeeds", see docs/17 H-1)
        if (order.sellToken.code.length == 0) revert Errors.InvalidOrder();
        if (order.trader != msg.sender) revert Errors.NotOrderOwner();

        // Batch guards
        uint64 epoch = currentEpoch();
        if (order.epoch != epoch) revert Errors.EpochClosed();
        if (_sealed[epoch]) revert Errors.EpochClosed();
        if (_epochOrders[epoch].length >= MAX_ORDERS_PER_EPOCH) revert Errors.BatchFull();
        if (order.validUntil <= block.number) revert Errors.InvalidOrder();
        if (order.validUntil > epochEndBlock(order.epoch + MAX_VALIDITY_EPOCHS)) revert Errors.InvalidOrder();

        // Signature guards
        orderId = OrderLib.orderHash(DOMAIN_SEPARATOR, order);
        if (!_verify(order.trader, orderId, signature)) revert Errors.InvalidSignature();

        // Idempotency guards
        if (_nonceUsed[order.trader][order.nonce]) revert Errors.NonceAlreadyUsed();
        if (_orderState[orderId] != uint8(OrderState.NONE)) revert Errors.InvalidOrder();

        // Write state first, then transfer (CEI); a failed transfer reverts the whole transaction
        _nonceUsed[order.trader][order.nonce] = true;
        _orders[orderId] = order;
        _orderEpoch[orderId] = epoch;
        _orderLocked[orderId] = order.sellAmount;
        _orderState[orderId] = uint8(OrderState.LOCKED);
        _epochOrders[epoch].push(orderId);

        // Deposit check: assert the actual amount received equals sellAmount, blocking malicious/malformed tokens that "return true but transfer nothing".
        uint256 balanceBefore = IERC20(order.sellToken).balanceOf(address(this));
        IERC20(order.sellToken).safeTransferFrom(order.trader, address(this), order.sellAmount);
        if (IERC20(order.sellToken).balanceOf(address(this)) - balanceBefore != order.sellAmount) {
            revert Errors.InvalidOrder();
        }

        emit OrderSubmitted(
            orderId, order.trader, epoch, order.sellToken, order.buyToken, order.sellAmount, order.minBuyAmount
        );
    }

    /// @notice Cancel an order before close; funds return to the owner. No cancellation past the batch boundary.
    function cancelOrder(bytes32 orderId) external nonReentrant {
        if (_orderState[orderId] != uint8(OrderState.LOCKED)) revert Errors.OrderNotFound();
        Order storage order = _orders[orderId];
        if (msg.sender != order.trader) revert Errors.NotOrderOwner();
        if (block.number >= epochEndBlock(_orderEpoch[orderId])) revert Errors.EpochClosed();
        if (_sealed[_orderEpoch[orderId]]) revert Errors.EpochClosed();

        _orderState[orderId] = uint8(OrderState.CANCELLED);
        uint256 amount = _orderLocked[orderId];
        _orderLocked[orderId] = 0;
        _transferExact(IERC20(order.sellToken), order.trader, amount);

        emit OrderCancelled(orderId, amount);
    }

    /// @notice After the deadline height, users reclaim funds unilaterally, with no signature needed.
    function claimExpired(bytes32 orderId) external nonReentrant {
        if (_orderState[orderId] == uint8(OrderState.NONE)) revert Errors.OrderNotFound();
        if (msg.sender != _orders[orderId].trader) revert Errors.NotOrderOwner();
        _refund(orderId);
    }

    /// @notice Refund triggered by the settlement contract.
    /// @dev Shares the same `_refund` logic and state guards as user self-service refunds, so the two paths are mutually exclusive by construction,
    ///      with no "settled and refunded" double-payment risk (the resolution for review item P1-6).
    function refundOnSettlement(bytes32 orderId, address requester) external override onlySettlement nonReentrant {
        if (_orderState[orderId] == uint8(OrderState.NONE)) revert Errors.OrderNotFound();
        if (requester != _orders[orderId].trader) revert Errors.NotOrderOwner();
        _refund(orderId);
    }

    /// @notice Settlement posting: `amountSold` is released to the solver, the remainder refunded to the trader, and the order marked SETTLED.
    function settleOrder(bytes32 orderId, uint256 amountSold, address solver) external onlySettlement nonReentrant {
        _settle(orderId, amountSold, solver);
    }

    /// @notice **Bulk** settlement posting: a whole batch in one external call (semantics identical to per-order `settleOrder`).
    /// @dev Only saves the per-call external-call overhead; per-order state writes and transfers are unchanged (see docs/11, option B).
    function settleBatch(bytes32[] calldata orderIds, uint256[] calldata amountSolds, address solver)
        external
        override
        onlySettlement
        nonReentrant
    {
        uint256 n = orderIds.length;
        if (n != amountSolds.length) revert Errors.InvalidOrder();
        for (uint256 i = 0; i < n; i++) {
            _settle(orderIds[i], amountSolds[i], solver);
        }
    }

    /// @dev RT-14: after a transfer, check the recipient's balance increased by **exactly** `amount` (skipped when the amount is 0).
    function _transferExact(IERC20 token, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = token.balanceOf(to);
        token.safeTransfer(to, amount);
        if (token.balanceOf(to) - before != amount) revert Errors.TransferNotSettled();
    }

    /// @dev The single implementation of settlement posting, shared by the per-order and bulk entry points.
    function _settle(bytes32 orderId, uint256 amountSold, address solver) private {
        uint8 state = _orderState[orderId];
        if (state == uint8(OrderState.NONE)) revert Errors.OrderNotFound();
        if (state >= uint8(OrderState.FILLED)) revert Errors.AlreadySettled();
        if (solver == address(0)) revert Errors.InvalidOrder();

        uint256 locked = _orderLocked[orderId];
        if (amountSold > locked) revert Errors.InvalidOrder();

        Order storage order = _orders[orderId];
        _orderState[orderId] = uint8(OrderState.SETTLED);
        _orderLocked[orderId] = 0;

        // RT-14 (red-team freeze-1): payouts must actually arrive — `safeTransfer` only checks the return value,
        // and a token that "returns true but transfers nothing" would let the batch settle as normal: the solver gets stiffed and the collateral is stuck.
        IERC20 token = IERC20(order.sellToken);
        uint256 remainder = locked - amountSold;
        _transferExact(token, solver, amountSold);
        _transferExact(token, order.trader, remainder);

        emit OrderSettled(orderId, solver, amountSold, remainder);
    }

    /// @dev Shared refund implementation: state guards guarantee mutual exclusion with settlement.
    function _refund(bytes32 orderId) private {
        uint8 state = _orderState[orderId];
        if (state == uint8(OrderState.NONE)) revert Errors.OrderNotFound();
        if (state >= uint8(OrderState.FILLED)) revert Errors.AlreadySettled();
        if (block.number <= epochDeadlineBlock(_orderEpoch[orderId])) revert Errors.RefundTooEarly();

        Order storage order = _orders[orderId];
        uint256 amount = _orderLocked[orderId];
        _orderState[orderId] = uint8(OrderState.REFUNDED);
        _orderLocked[orderId] = 0;
        _transferExact(IERC20(order.sellToken), order.trader, amount);

        emit OrderRefunded(orderId, order.trader, amount);
    }

    // ------------------------------------------------------------ Close commitment

    /// @notice Close the batch and store the order-set commitment.
    /// @dev The commitment is computed in submission order: `keccak(concat(ids))`. The contract computes it itself, with no sorting,
    ///      and it accepts no off-chain-provided list, so there is no "matcher drops an order" attack surface.
    function sealEpoch(uint64 epoch) external {
        if (_sealed[epoch]) revert Errors.EpochClosed();
        if (block.number < epochEndBlock(epoch)) revert Errors.EpochClosed();

        // Remove cancelled orders: they belong neither in the commitment nor in matching or settlement
        bytes32[] storage submitted = _epochOrders[epoch];
        bytes32[] storage eligible = _sealedOrders[epoch];
        uint256 submittedCount = submitted.length;
        for (uint256 i = 0; i < submittedCount; i++) {
            bytes32 id = submitted[i];
            if (_orderState[id] == uint8(OrderState.CANCELLED)) continue;
            eligible.push(id);
        }

        uint256 n = eligible.length;
        bytes memory buffer = new bytes(n * 32);
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = eligible[i];
            assembly {
                mstore(add(add(buffer, 32), mul(i, 32)), id)
            }
        }

        bytes32 commitment = keccak256(buffer);
        _orderSetHash[epoch] = commitment;
        _sealed[epoch] = true;
        sealedAtBlock[epoch] = block.number;

        emit EpochSealed(epoch, commitment, n);
    }

    // ------------------------------------------------------------ Internal

    /// @dev Order signatures: verified after EIP-191 personal_sign wrapping; high s values are rejected and `v` is constrained to {27,28}
    ///      (audit report L-1: without the constraint, the code would rely on ecrecover returning the zero address for an abnormal v — a defense-in-depth gap).
    function _verify(address signer, bytes32 digest, bytes calldata signature) private pure returns (bool) {
        if (signature.length != 65) return false;

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v != 27 && v != 28) return false;

        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return false;
        return ecrecover(OrderLib.ethSigned(digest), v, r, s) == signer;
    }
}
