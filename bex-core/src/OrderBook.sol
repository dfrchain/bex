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
/// @notice 接收并校验签名订单、锁定用户资产、按批次归档、封盘时生成订单集合承诺。
/// @dev 关键设计（见 docs/05）：
///      - 订单按**提交顺序**入库，封盘承诺 `keccak(concat(ids))` 由合约自算，不排序、不信任链下；
///      - 完整性由结算侧用"提交序号 + 位图"校验；
///      - 到期取回与结算两条路径互斥（状态机保证）；
///      - 批次与订单参数是**部署期参数**（`MatchParams.Config`，带上下界与交叉不变量），
///        第一版决策值不变；参数登记见 `docs/31-参数分层注册表（草案）.md`。
contract OrderBook is IOrderBook {
    using SafeTransfer for IERC20;

    /// @notice 批次长度（源链区块数）。部署期参数；第一版决策值 30（`spec/09`）。
    uint256 public immutable EPOCH_BLOCKS;
    /// @notice 单批订单上限。部署期参数；第一版决策值 200。
    uint256 public immutable MAX_ORDERS_PER_EPOCH;
    /// @notice 单笔字段上界。部署期参数；第一版决策值 2^120−1（`uint120` 字段上限）。
    uint256 public immutable MAX_ORDER_VALUE;
    /// @notice 订单有效期最多延伸到下单批次之后的批次数。部署期参数；第一版决策值 10。
    uint64 public immutable MAX_VALIDITY_EPOCHS;

    /// @notice 签名域分隔符，绑定域名称、版本、链 ID 与合约地址。
    bytes32 public immutable DOMAIN_SEPARATOR;
    /// @notice 批次边界之后允许回执提交的区块数（45 分钟对应值由部署方按链给出）。
    uint256 public immutable REFUND_DELAY_BLOCKS;
    /// @notice 部署者：仅用于一次性绑定结算合约。
    address public immutable deployer;
    /// @notice 结算合约地址，一次性绑定后不可更改。
    address public settlement;

    mapping(bytes32 => uint8) private _orderState;
    mapping(uint64 => bytes32[]) private _epochOrders;
    /// @dev 封盘时确定的可撮合集合：剔除已取消订单，提交顺序保持不变。
    mapping(uint64 => bytes32[]) private _sealedOrders;
    mapping(uint64 => bytes32) private _orderSetHash;
    mapping(uint64 => bool) private _sealed;
    mapping(address => mapping(uint256 => bool)) private _nonceUsed;
    mapping(bytes32 => Order) private _orders;
    mapping(bytes32 => uint64) private _orderEpoch;
    mapping(bytes32 => uint256) private _orderLocked;

    /// @notice 代币准入开关（RT-31 / 红队第三轮 R3-01）：开启后只放行运营方核验过的币种。
    /// @dev 为什么必须在**订单簿入口**：出金短付 / 重基类代币会让 `_transferExact` 在
    ///      `claimExpired`/`cancelOrder` 上永久回滚，用户本金锁死且没有应急提取入口。
    ///      只在拍卖登记表上做白名单盖不住公开档（`PlaintextMatchVerifier` 不读登记表）。
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

    /// @notice 部署期参数校验与落地（越界在构造期 revert，见 `MatchParams.validate`）。
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

    /// @notice 当前生效的部署期参数。运维/监控/审计从这里读，不要在链下各自硬编码（docs/31 第十节-5）。
    function params() external view returns (MatchParams.Config memory) {
        return MatchParams.Config({
            epochBlocks: EPOCH_BLOCKS,
            maxOrdersPerEpoch: MAX_ORDERS_PER_EPOCH,
            maxOrderValue: MAX_ORDER_VALUE,
            maxValidityEpochs: MAX_VALIDITY_EPOCHS,
            refundDelayBlocks: REFUND_DELAY_BLOCKS
        });
    }

    /// @notice 一次性绑定结算合约。只能由部署者调用，且只能调用一次。
    /// @dev 本方案不引入可升级代理：绑定后结算地址永久固定，减少权限面。
    function bindSettlement(address settlement_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (settlement != address(0)) revert Errors.AlreadySet();
        if (settlement_ == address(0)) revert Errors.InvalidOrder();
        settlement = settlement_;
        emit SettlementBound(settlement_);
    }

    // ------------------------------------------------------------ 代币准入（RT-31）

    /// @notice 开关"下单必须命中币种白名单"。仅部署者（运营方）。
    function setTokenAdmissionRequired(bool required) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        tokenAdmissionRequired = required;
        emit TokenAdmissionRequiredSet(required);
    }

    /// @notice 登记 / 撤销一个可交易币种。仅部署者；撤销只影响**之后**的下单。
    /// @dev 运营方的核验口径（至少）：转账不扣费、非重基、无转账开关、非黑名单制。
    ///      链上无法自动判定这些性质，因此这里只做"白名单事实"记录，检测留给运营方与监控。
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

    // ------------------------------------------------------------ 批次时钟

    /// @notice 当前批次号 = 源链高度 / 批次长度（向下取整）。
    function currentEpoch() public view returns (uint64) {
        // EPOCH_BLOCKS >= 3；要截断 uint64 至少需 2^64×3 个区块，远超链的可达寿命。
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.number / EPOCH_BLOCKS);
    }

    /// @notice 批次起始高度（含）。
    function epochStartBlock(uint64 epoch) public view returns (uint256) {
        return uint256(epoch) * EPOCH_BLOCKS;
    }

    /// @notice 批次结束高度（不含）。到达该高度即可封盘。
    function epochEndBlock(uint64 epoch) public view returns (uint256) {
        return uint256(epoch + 1) * EPOCH_BLOCKS;
    }

    /// @notice 回执提交截止高度（源链解释）。超过该高度用户可取回资产。
    function epochDeadlineBlock(uint64 epoch) public view override returns (uint256) {
        return epochEndBlock(epoch) + REFUND_DELAY_BLOCKS;
    }

    // ------------------------------------------------------------ 查询

    /// @notice 订单哈希（供客户端签名与第三方复算）。
    function orderHashOf(Order calldata order) external view returns (bytes32) {
        return OrderLib.orderHash(DOMAIN_SEPARATOR, order);
    }

    /// @notice 查询订单内容。
    function orderOf(bytes32 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice 查询订单状态，返回 `OrderState` 的 uint8 值。
    function orderState(bytes32 orderId) external view returns (uint8) {
        return _orderState[orderId];
    }

    /// @notice 查询某批次的订单集合（提交顺序；封盘后为剔除取消件后的集合）。
    function epochOrders(uint64 epoch) external view returns (bytes32[] memory) {
        if (_sealed[epoch]) return _sealedOrders[epoch];
        return _epochOrders[epoch];
    }

    /// @notice 某批次的订单数量（封盘后为剔除取消件后的数量）。
    function epochOrderCount(uint64 epoch) external view returns (uint256) {
        if (_sealed[epoch]) return _sealedOrders[epoch].length;
        return _epochOrders[epoch].length;
    }

    /// @notice 取某批次在**提交顺序**中第 i 个订单的 ID（封盘后基于剔除取消件后的集合）。
    function epochOrderIdAt(uint64 epoch, uint256 index) external view returns (bytes32) {
        if (_sealed[epoch]) return _sealedOrders[epoch][index];
        return _epochOrders[epoch][index];
    }

    /// @notice **批量**取某批次的全部订单 ID（提交顺序）。供结算合约一次取回，避免逐单外部调用。
    /// @dev Gas 实测（N=200）：逐单 `epochOrderIdAt` + `orderOf` 合计约 3.9M gas，
    ///      改为本函数 + `ordersOf` 两次批量调用后降到约 0.3M（见 docs/05 第十九节）。
    function epochOrderIds(uint64 epoch) external view returns (bytes32[] memory ids) {
        bytes32[] storage source = _sealed[epoch] ? _sealedOrders[epoch] : _epochOrders[epoch];
        uint256 n = source.length;
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = source[i];
        }
    }

    /// @notice **批量**取某批次全部订单的内容，顺序与 `epochOrderIds` 一致。
    function epochOrderContents(uint64 epoch) external view returns (Order[] memory orders) {
        bytes32[] storage source = _sealed[epoch] ? _sealedOrders[epoch] : _epochOrders[epoch];
        uint256 n = source.length;
        orders = new Order[](n);
        for (uint256 i = 0; i < n; i++) {
            orders[i] = _orders[source[i]];
        }
    }

    /// @notice 已保存的订单集合承诺（提交顺序）。
    function orderSetHashOf(uint64 epoch) external view override returns (bytes32) {
        return _orderSetHash[epoch];
    }

    /// @notice 公开档提供明文有效期：`Settlement` 因此可以逐单校验 `validUntil`（档位无关的时限校验）。
    function exposesPlaintextValidity() external pure returns (bool) {
        return true;
    }

    /// @notice 某批次是否已封盘。
    function isSealed(uint64 epoch) external view override returns (bool) {
        return _sealed[epoch];
    }

    // ------------------------------------------------------------ 提交与取消

    /// @notice 提交订单并锁定资产。
    function submitOrder(Order calldata order, bytes calldata signature)
        external
        nonReentrant
        returns (bytes32 orderId)
    {
        // 结构守卫
        if (order.trader == address(0)) revert Errors.InvalidOrder();
        if (order.sellToken == address(0) || order.buyToken == address(0)) revert Errors.InvalidOrder();
        if (order.sellToken == order.buyToken) revert Errors.InvalidOrder();
        if (order.sellAmount == 0 || order.minBuyAmount == 0) revert Errors.InvalidOrder();
        if (order.sellAmount > MAX_ORDER_VALUE || order.minBuyAmount > MAX_ORDER_VALUE) revert Errors.InvalidOrder();
        // RT-31（红队第三轮 R3-01）：代币准入门在**入口**，而不是只挂在拍卖登记表上。
        // 买侧也要放行——结算时要把 buyToken 付给这位交易者，坏币种同样会让出金路径回滚。
        if (tokenAdmissionRequired && (!tokenAllowed[order.sellToken] || !tokenAllowed[order.buyToken])) {
            revert Errors.TokenNotAllowed();
        }
        // 审计 L-2：`partiallyFillable=false`（全有或全无）在第一版尚未实现语义，
        // 为避免"用户签了意思表示却不生效"，此处**明确拒绝**而不是静默部分成交。
        // 实现该语义（链上 + 链下引擎 + 规范）后再放开，见 docs/17 L-2。
        if (!order.partiallyFillable) revert Errors.InvalidOrder();
        // 卖出资产必须是合约（否则 EOA 上的 transferFrom 会"静默成功"，见 docs/17 H-1）
        if (order.sellToken.code.length == 0) revert Errors.InvalidOrder();
        if (order.trader != msg.sender) revert Errors.NotOrderOwner();

        // 批次守卫
        uint64 epoch = currentEpoch();
        if (order.epoch != epoch) revert Errors.EpochClosed();
        if (_sealed[epoch]) revert Errors.EpochClosed();
        if (_epochOrders[epoch].length >= MAX_ORDERS_PER_EPOCH) revert Errors.BatchFull();
        if (order.validUntil <= block.number) revert Errors.InvalidOrder();
        if (order.validUntil > epochEndBlock(order.epoch + MAX_VALIDITY_EPOCHS)) revert Errors.InvalidOrder();

        // 签名守卫
        orderId = OrderLib.orderHash(DOMAIN_SEPARATOR, order);
        if (!_verify(order.trader, orderId, signature)) revert Errors.InvalidSignature();

        // 幂等守卫
        if (_nonceUsed[order.trader][order.nonce]) revert Errors.NonceAlreadyUsed();
        if (_orderState[orderId] != uint8(OrderState.NONE)) revert Errors.InvalidOrder();

        // 先写状态，再转账（CEI）；转账失败则整笔回滚
        _nonceUsed[order.trader][order.nonce] = true;
        _orders[orderId] = order;
        _orderEpoch[orderId] = epoch;
        _orderLocked[orderId] = order.sellAmount;
        _orderState[orderId] = uint8(OrderState.LOCKED);
        _epochOrders[epoch].push(orderId);

        // 入账校验：断言实际到账等于 sellAmount，挡住"返回 true 但不转账"的恶意/畸形代币
        uint256 balanceBefore = IERC20(order.sellToken).balanceOf(address(this));
        IERC20(order.sellToken).safeTransferFrom(order.trader, address(this), order.sellAmount);
        if (IERC20(order.sellToken).balanceOf(address(this)) - balanceBefore != order.sellAmount) {
            revert Errors.InvalidOrder();
        }

        emit OrderSubmitted(
            orderId, order.trader, epoch, order.sellToken, order.buyToken, order.sellAmount, order.minBuyAmount
        );
    }

    /// @notice 封盘前取消订单，资产退回本人。越过批次边界后不可取消。
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

    /// @notice 超过截止高度后由用户单方取回资产，不依赖任何签名。
    function claimExpired(bytes32 orderId) external nonReentrant {
        if (_orderState[orderId] == uint8(OrderState.NONE)) revert Errors.OrderNotFound();
        if (msg.sender != _orders[orderId].trader) revert Errors.NotOrderOwner();
        _refund(orderId);
    }

    /// @notice 由结算合约触发的退款。
    /// @dev 与用户自助退款共用同一段 `_refund` 逻辑与同一状态守卫，因此两条路径天然互斥，
    ///      不存在"既结算又退款"的双付风险（评审 P1-6 的处置）。
    function refundOnSettlement(bytes32 orderId, address requester) external override onlySettlement nonReentrant {
        if (_orderState[orderId] == uint8(OrderState.NONE)) revert Errors.OrderNotFound();
        if (requester != _orders[orderId].trader) revert Errors.NotOrderOwner();
        _refund(orderId);
    }

    /// @notice 结算落账：`amountSold` 释放给求解者，剩余退回交易者，订单置为 SETTLED。
    function settleOrder(bytes32 orderId, uint256 amountSold, address solver) external onlySettlement nonReentrant {
        _settle(orderId, amountSold, solver);
    }

    /// @notice **批量**结算落账：一次外部调用完成整批（语义与逐单 `settleOrder` 完全一致）。
    /// @dev 只省外部调用框架开销，逐单的状态写入与转账照旧（见 docs/11 方案 B）。
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

    /// @dev RT-14：转账后校验收款人余额**恰好**增加 `amount`（金额为 0 跳过）。
    function _transferExact(IERC20 token, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = token.balanceOf(to);
        token.safeTransfer(to, amount);
        if (token.balanceOf(to) - before != amount) revert Errors.TransferNotSettled();
    }

    /// @dev 结算落账的单一实现，逐单与批量两条入口共用。
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

        // RT-14（红队 freeze-1）：出金必须真的到账——`safeTransfer` 只校验返回值，
        // "返回 true 但不转账"的代币会让批次照常结算：求解者被白嫖、抵押品困死。
        IERC20 token = IERC20(order.sellToken);
        uint256 remainder = locked - amountSold;
        _transferExact(token, solver, amountSold);
        _transferExact(token, order.trader, remainder);

        emit OrderSettled(orderId, solver, amountSold, remainder);
    }

    /// @dev 退款统一实现：状态守卫保证与结算互斥。
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

    // ------------------------------------------------------------ 封盘承诺

    /// @notice 封盘并保存订单集合承诺。
    /// @dev 承诺按提交顺序计算：`keccak(concat(ids))`。合约自算，不需要排序，
    ///      也不接受任何链下提供的列表，因此不存在"撮合方漏掉订单"的攻击面。
    function sealEpoch(uint64 epoch) external {
        if (_sealed[epoch]) revert Errors.EpochClosed();
        if (block.number < epochEndBlock(epoch)) revert Errors.EpochClosed();

        // 剔除已取消订单：它们既不应进入承诺，也不应参与撮合或结算
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

    // ------------------------------------------------------------ 内部

    /// @dev 订单签名：EIP-191 personal_sign 包装后校验；拒绝高 s 值，并把 `v` 约束到 {27,28}
    ///      （审计报告 L-1：不做约束时依赖 ecrecover 对异常 v 返回零地址，属纵深防御缺口）。
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
