// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IAttestationVerifier } from "./interfaces/IAttestationVerifier.sol";
import { IMatchVerifier } from "./interfaces/IMatchVerifier.sol";
import { IOrderBook } from "./interfaces/IOrderBook.sol";
import { Errors } from "./libraries/Errors.sol";
import { SolverRegistry } from "./SolverRegistry.sol";
import { BatchSettlement, Order } from "./types/BexTypes.sol";

/// @title Settlement
/// @notice 校验回执与结算窗口、按成交明细落账，并处理退款。**不自行复算撮合结果**：
///         撮合有效性交给按档位实现的 `IMatchVerifier`（公开档 = `PlaintextMatchVerifier`），
///         因此结算层不读任何订单内容（见 `docs/09-档位预留接口规范.md` 第二、三节）。
/// @dev 校验顺序决定各类攻击命中哪个错误码：
///      1. 链 ID 绑定 → WrongChain
///      2. 摘要是否已消费 → DigestAlreadyConsumed
///      3. 同批次是否已结算 → MultiplePrices
///      4. 批次是否封盘 → EpochClosed
///      5. 集合承诺与交易对定义 → OrderSetMismatch / InvalidOrder
///      6. 撮合有效性 → 由 `matchVerifier.verifyMatch` 决定（公开档会报 OrderSetMismatch /
///         PayloadNotPriceOrdered / RecomputeMismatch / BelowUserLimit）
///      7. 结算窗口 → InvalidOrder / EpochClosed（注：载荷 `deadline` 的越窗检查在
///         `matchVerifier.verifyMatch` **之后**，让档位自身的错误码（如密封档的 RevealExpired）
///         优先暴露；第 8 轮审计 L-02 记录了这一顺序，注释与实现保持一致）
///      8. 求解者门槛 → NotRegistered / SolverBondInsufficient
///      9. 回执签名 → AttestationInvalid
contract Settlement {
    bytes32 private constant SETTLEMENT_DOMAIN = keccak256("BEX_SETTLEMENT");

    IAttestationVerifier public immutable verifier;
    /// @notice 订单簿依赖已抽成接口：公开档与密封档共用本结算合约（见 `IOrderBook` 注释）。
    IOrderBook public immutable orderBook;
    /// @notice 撮合有效性验证器：按档位实现。结算层只通过 `verifyMatch` 与它交互（档位隔离在部署层）。
    IMatchVerifier public immutable matchVerifier;
    /// @notice 部署者：仅用于一次性绑定 `SolverRegistry`（与 OrderBook 的绑定模式一致）。
    address public immutable deployer;
    /// @notice 求解者注册表：绑定后结算前校验"已注册且保证金足额"；未绑定（address(0)）则跳过。
    SolverRegistry public solverRegistry;
    /// @notice 批次 -> 被派单的求解者（链上派单记账，docs/20）。
    event SolverAllowedSet(address indexed solver, bool allowed);

    mapping(uint64 => address) public dispatchedSolver;
    /// @notice 求解者白名单（RT-15，红队 freeze-1）：第一版为**协议自营求解者**（docs/12 §五.2），
    ///         若不做白名单，任何新注册的求解者都能用一笔 `dispatch` 先占死某个 epoch 的派单位，
    ///         把该批次拖到超时退款（用户不受损，但批次被杀）。仅 `deployer`（运营方）可维护。
    mapping(address => bool) public solverAllowed;
    /// @notice Monotonic emergency revocation generation for all historical
    ///         obligations of a solver. Reauthorization never revives them.
    mapping(address => uint256) public solverAuthorizationGeneration;
    /// @dev **派单时锁定的敞口额度**（第三轮补充复核 A）：必须在派单时落库，
    ///      否则结算/超时释放时重算 `maxSingleOrderSize` 会因求解者中途追加保证金而变大，
    ///      导致 `closeExposure` 数额不匹配 → 批次与保证金被永久锁死。
    mapping(uint64 => uint256) public dispatchHold;
    /// @notice 罚没控制器（D-4：第一版由多签 + timelock 触发）。只有它能调用 `slashSolver`。
    address public slashController;

    mapping(bytes32 => bool) private _consumedDigest;
    /// @dev RT-4（红队 freeze-1）：摘要 → 消费时所在纪元。`settledDigest` 只说明"被消费过"，
    ///      跨 epoch 锚定需要知道"这个摘要属于哪一批"。
    mapping(bytes32 => uint64) private _digestEpoch;
    mapping(uint64 => bool) private _epochSettled;

    uint256 private _reentrancyLock = 1;

    event BatchSettled(
        uint64 indexed epoch,
        bytes32 indexed pairHash,
        uint256 priceNum,
        uint256 priceDen,
        uint256 volume,
        bytes32 orderSetHash,
        bytes32 matcherVersion,
        address indexed solver
    );
    event Refunded(bytes32 indexed orderId);
    event SolverRegistryBound(address indexed registry);
    event RegistryRequirementChanged(bool required);
    event BatchDispatched(uint64 indexed epoch, address indexed solver, uint256 hold);
    event ExposureReleased(uint64 indexed epoch, address indexed solver, uint256 hold);
    event SlashControllerBound(address indexed controller);
    event SolverSlashed(bytes32 indexed solverId, uint256 amount, bytes32 reason);

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert Errors.Reentrant();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    constructor(IAttestationVerifier verifier_, IOrderBook orderBook_, IMatchVerifier matchVerifier_) {
        verifier = verifier_;
        orderBook = orderBook_;
        matchVerifier = matchVerifier_;
        deployer = msg.sender;
    }

    /// @notice 是否要求先绑定 `SolverRegistry` 才能结算（默认 true）。
    /// @dev 生产与测试网部署必须保持 true；本地演练可用一次性 `setRegistryRequired(false)` 关闭。
    bool private _registryRequired = true;

    function registryRequired() external view returns (bool) {
        return _registryRequired;
    }

    /// @notice 部署者可**一次性**关闭"必须绑定注册表"的要求（仅供本地演练）。
    function setRegistryRequired(bool required) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (!_registryRequired) revert Errors.AlreadySet();
        // R4-4：关闭门槛**只允许在本地链**（供单测/演练），避免在生产部署上被误关
        if (!required) {
            require(block.chainid == 31337 || block.chainid == 31338, "registry opt-out is local-only");
        }
        _registryRequired = required;
        emit RegistryRequirementChanged(required);
    }

    /// @notice 一次性绑定求解者注册表（审计 M-2）。绑定后不可更改；不引入可升级代理。
    function bindSolverRegistry(SolverRegistry registry_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (address(registry_) == address(0)) revert Errors.InvalidOrder(); // M-4：零地址会永久关闭门槛
        if (address(solverRegistry) != address(0)) revert Errors.AlreadySet();
        solverRegistry = registry_;
        emit SolverRegistryBound(address(registry_));
    }

    /// @notice **链上派单**（docs/20）：封盘后、截止前认领批次，并锁定该批次的敞口。
    /// @dev 派单发生在结算之前，链上此刻还不知道出清价与成交量，因此每批锁定一个保守且可预测的额度
    ///      `maxSingleOrderSize(solverId)`（= 保证金 × 5%）；`maxTotalExposure`（×50%）天然限制在途批次 ≤ 10。
    ///      锁定的效果由 `SolverRegistry.withdrawBond`/`requestExit` 的 `exposure == 0` 要求自动实现：
    ///      **派单到结算之间求解者无法提取保证金**（第三轮复核 M-2）。
    /// @notice 维护求解者白名单（仅部署者/运营方）。RT-15。
    function setSolverAllowed(address solver, bool allowed) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (solver == address(0)) revert Errors.InvalidOrder();
        if (solverAllowed[solver] && !allowed) {
            // A true->false revocation is a permanent fence for prior
            // canonical receipts; a later grant creates a fresh generation.
            ++solverAuthorizationGeneration[solver];
        }
        solverAllowed[solver] = allowed;
        emit SolverAllowedSet(solver, allowed);
    }

    function dispatch(uint64 epoch, address solver) external {
        if (address(solverRegistry) == address(0)) revert Errors.NotRegistered();
        if (!orderBook.isSealed(epoch)) revert Errors.EpochClosed();
        if (block.number > orderBook.epochDeadlineBlock(epoch)) revert Errors.EpochClosed();
        if (dispatchedSolver[epoch] != address(0)) revert Errors.AlreadySet();
        if (solver == address(0)) revert Errors.InvalidOrder();
        // 第三轮补充复核 B：派单必须由**被派单者本人**发起，否则任何人可用零成本
        // 耗尽他人敞口额度（拒绝服务）。第一版为协议自营求解者，故要求 msg.sender == solver。
        if (msg.sender != solver) revert Errors.NotOrderOwner();
        // RT-15：白名单放行（默认拒绝）。运营方在部署后显式 `setSolverAllowed`。
        if (!solverAllowed[solver]) revert Errors.NotRegistered();

        bytes32 solverId = solverRegistry.solverIdOf(solver);
        if (solverId == bytes32(0) || !solverRegistry.isRegistered(solverId)) revert Errors.NotRegistered();

        uint256 hold = solverRegistry.maxSingleOrderSize(solverId);
        dispatchedSolver[epoch] = solver;
        dispatchHold[epoch] = hold;
        solverRegistry.openExposure(solverId, epoch, hold);
        emit BatchDispatched(epoch, solver, hold);
    }

    /// @notice **超时释放敞口**：越过批次截止高度且该批次未结算时，任何人可调用（用户照常走退款）。
    function releaseExpiredExposure(uint64 epoch) external {
        address solver = dispatchedSolver[epoch];
        if (solver == address(0)) revert Errors.NotRegistered();
        if (block.number <= orderBook.epochDeadlineBlock(epoch)) revert Errors.RefundTooEarly();
        if (_epochSettled[epoch]) revert Errors.AlreadySettled();

        bytes32 solverId = solverRegistry.solverIdOf(solver);
        uint256 hold = dispatchHold[epoch];
        dispatchedSolver[epoch] = address(0);
        dispatchHold[epoch] = 0;
        solverRegistry.closeExposure(solverId, epoch, hold);
        emit ExposureReleased(epoch, solver, hold);
    }

    /// @notice 一次性绑定罚没控制器（D-4）。绑定后不可更改；未绑定则 `slashSolver` 不可用。
    /// @dev `SolverRegistry.slash` 是 `onlySettlement`，所以"多签 + timelock"必须经结算合约转发。
    ///      在此之前罚没在链上**没有任何可达路径**（`docs/19-签字建议单` §三 的 D-4 待办）。
    function bindSlashController(address controller_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (controller_ == address(0)) revert Errors.InvalidOrder();
        if (slashController != address(0)) revert Errors.AlreadySet();
        // 第 8 轮审计 H-01/L-03：控制器必须是**合约**（多签/timelock），不得绑定 EOA——
        // 否则"多签 + 延时"会静默退化为单密钥控制。
        if (controller_.code.length == 0) revert Errors.InvalidOrder();
        slashController = controller_;
        emit SlashControllerBound(controller_);
    }

    /// @notice 罚没求解者（D-4：多签 + timelock 触发）。只有 `slashController` 可调用。
    /// @dev 扣减上限由 `SolverRegistry.slash` 保证（最多扣完该求解者保证金，不追索风险池之外）。
    ///      本函数**不自带延时**：延时由控制器在执行前保证（参考 `src/SlashTimelock.sol`）。
    function slashSolver(bytes32 solverId, uint256 amount, bytes32 reason) external nonReentrant {
        if (msg.sender != slashController) revert Errors.NotSlashController();
        if (address(solverRegistry) == address(0)) revert Errors.NotRegistered();
        solverRegistry.slash(solverId, amount, reason);
        emit SolverSlashed(solverId, amount, reason);
    }

    // ------------------------------------------------------------ 摘要

    /// @notice 结算摘要：绑定链 ID、结算合约地址与**具体成交明细**，防跨链重放与"换分配"。
    /// @dev `06` 第六节要求摘要绑定链与合约；2026-09-25 追加 `keccak256(abi.encode(fills))`：
    ///      在此之前，同一份回执可在"最大余数解集"内换成另一份分配（每单差异 ≤1 最小单位），
    ///      验证者签的就不是"这一份分配"。见 docs/17 中-2 与 docs/05 第二十七节。
    function settlementDigestOf(BatchSettlement calldata batch) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                SETTLEMENT_DOMAIN,
                block.chainid,
                address(this),
                batch.epoch,
                batch.pairHash,
                batch.priceNum,
                batch.priceDen,
                batch.volume,
                batch.orderSetHash,
                batch.solver,
                batch.deadline,
                batch.matcherVersion,
                keccak256(abi.encode(batch.fills))
            )
        );
    }

    function settledDigest(bytes32 digest) external view returns (bool) {
        return _consumedDigest[digest];
    }

    /// @notice 该摘要被消费时所在的纪元（未消费过为 0）。跨 epoch 锚定校验用（RT-4）。
    function epochOfDigest(bytes32 digest) external view returns (uint64) {
        return _digestEpoch[digest];
    }

    function epochSettled(uint64 epoch) external view returns (bool) {
        return _epochSettled[epoch];
    }

    // ------------------------------------------------------------ 结算

    /// @notice 结算一个批次。任何人都可提交，只要回执有效且复算一致。
    function settle(BatchSettlement calldata batch, bytes calldata attestation, bytes calldata matchProof)
        external
        nonReentrant
    {
        if (batch.chainId != block.chainid) revert Errors.WrongChain();

        bytes32 digest = settlementDigestOf(batch);
        if (_consumedDigest[digest]) revert Errors.DigestAlreadyConsumed();
        if (_epochSettled[batch.epoch]) revert Errors.MultiplePrices();

        if (!orderBook.isSealed(batch.epoch)) revert Errors.EpochClosed();
        if (orderBook.orderSetHashOf(batch.epoch) != batch.orderSetHash) revert Errors.OrderSetMismatch();
        if (batch.pairHash != keccak256(abi.encode(batch.baseToken, batch.quoteToken))) {
            revert Errors.InvalidOrder();
        }
        // 载荷声明的结算窗口不得超过链上退款窗口（可自选更短窗口）。
        // 空载荷（deadline=0）在此放行，交由验证器报结构错误（OrderSetMismatch），保持错误码语义。
        if (batch.deadline > orderBook.epochDeadlineBlock(batch.epoch)) revert Errors.InvalidOrder();

        // 撮合有效性：绑定校验 → 复算清算价 → 与载荷比对 → 成交量上下界 → 分配校验
        // （含逐笔限价与两侧守恒）。这些校验都需要订单内容，因此住在按档位实现的验证器里；
        // 结算层不读订单内容，只消费它复算出的成交量（docs/09 第二节与 §3.1）。
        uint256 volume = matchVerifier.verifyMatch(batch, matchProof);

        // 结算窗口（第三轮补充复核 C：与档位无关）。放在验证器之后：结构类/揭示类错误由各档验证器
        // 先报（OrderSetMismatch / RevealExpired），越窗才报 EpochClosed——既有错误码口径不变。
        if (block.number > batch.deadline) revert Errors.EpochClosed();
        // 逐单有效期（RT-16 语义 B，2026-09-27）：**过期订单不参与撮合**——它仍留在封盘集合里
        // （集合绑定与集合哈希都不变），但一旦出现成交即拒绝。该规则住在各档验证器里，因为它需要
        // 与 fills 的对齐关系（O(n+f)）；在结算层逐单反查 fills 是 O(n·f)，200 单下要多花几 M gas。
        //   公开档：`PlaintextMatchVerifier._verifyFills`（对齐时校验）+ `_scan` 跳过过期单；
        //   密封档：`SealedMatchVerifier._verifyAllocation`（对齐时校验）。
        // 新增档位必须回答同一个问题（接口注释不变）。

        // 求解者风控门槛（审计 M-2 与第二轮 N-1/N-2）：
        //   ① 未绑定注册表 → **拒绝**（原先静默跳过，等于门槛消失；本地演练可用 setRegistryRequired(false) 放开）
        //   ② 已注册 + 保证金 ≥ minBond
        //   ③ **敞口下界约束**：单批名义额不得超过单笔上限、不得超过可用保证金、计入后不得超过总敞口上限
        // 完整的敞口窗口记账（open/closeExposure）仍属"派单"步骤（D-4 已确认），
        // 但这里的下界约束保证"保证金至少覆盖单批名义额"，不再是一张入场券。
        // An emergency allowlist revocation must fence an already-dispatched
        // solver at final settlement, not only at initial dispatch. Expired
        // exposure release and user refund are still independently available.
        // Even if a local simulation opted out of *requiring* a registry,
        // a batch dispatched through a bound registry must still respect
        // post-dispatch emergency solver revocation at final settlement.
        if (address(solverRegistry) != address(0) && !solverAllowed[batch.solver]) {
            revert Errors.NotRegistered();
        }
        if (_registryRequired && address(solverRegistry) == address(0)) revert Errors.NotRegistered();
        if (address(solverRegistry) != address(0)) {
            // `notionalQuote` 和 registry 的 bond/exposure 都必须是同一资产单位；在没有
            // 经过审计的价格预言机前，跨资产比较会给出没有经济意义的风险上限。
            if (batch.quoteToken != address(solverRegistry.bondToken())) revert Errors.SolverBondTokenMismatch();
            // M-2/M-3（docs/20）：必须由**本批次被派单的求解者**结算
            if (dispatchedSolver[batch.epoch] != batch.solver) revert Errors.NotRegistered();
            bytes32 solverId = solverRegistry.solverIdOf(batch.solver);
            if (solverId == bytes32(0) || !solverRegistry.isRegistered(solverId)) {
                revert Errors.NotRegistered();
            }
            if (solverRegistry.bondOf(solverId) < solverRegistry.minBond()) {
                revert Errors.SolverBondInsufficient();
            }
            uint256 notionalQuote = (volume * batch.priceNum) / batch.priceDen;
            if (notionalQuote > solverRegistry.maxSingleOrderSize(solverId)) {
                revert Errors.SolverExposureExceeded();
            }
            // RT-2（红队 freeze-1）：本批在 `dispatch` 时已 `openExposure(hold)`，hold 已计入总敞口；
            // 这里若再按"敞口 + 本批名义额"检查，本批预留会被算两次——在合法配置
            // `singleOrderBps == totalExposureBps` 下永远结不了算，出厂参数下第 10 个并发批次也结不了。
            // 正确口径：把本批自己的预留从已用敞口中剔除，再核对"其余敞口 + 本批名义额 ≤ 总上限"。
            uint256 cap = solverRegistry.maxTotalExposure(solverId);
            uint256 used = solverRegistry.exposure(solverId);
            uint256 hold = dispatchHold[batch.epoch];
            uint256 usedOther = used > hold ? used - hold : 0;
            if (usedOther + notionalQuote > cap) revert Errors.SolverExposureExceeded();
        }

        if (!verifier.verify(digest, attestation)) revert Errors.AttestationInvalid();

        _consumedDigest[digest] = true;
        _digestEpoch[digest] = batch.epoch;
        _epochSettled[batch.epoch] = true;

        _applyFills(batch, volume);

        // 结算成功：关闭派单时锁定的敞口（若已绑定注册表）
        if (address(solverRegistry) != address(0)) {
            bytes32 solverId = solverRegistry.solverIdOf(batch.solver);
            uint256 hold = dispatchHold[batch.epoch];
            dispatchHold[batch.epoch] = 0;
            solverRegistry.closeExposure(solverId, batch.epoch, hold);
        }

        emit BatchSettled(
            batch.epoch,
            batch.pairHash,
            batch.priceNum,
            batch.priceDen,
            volume,
            batch.orderSetHash,
            batch.matcherVersion,
            batch.solver
        );
    }

    /// @notice 退款入口。与用户自助退款共用 OrderBook 的同一段逻辑与状态守卫，两条路径互斥。
    function refund(bytes32 orderId) external nonReentrant {
        orderBook.refundOnSettlement(orderId, msg.sender);
        emit Refunded(orderId);
    }

    // ------------------------------------------------------------ 内部

    /// @dev 落账（docs/09 §3.3 第 8 步）：把成交明细按封盘顺序映射成数组，一次批量交给 OrderBook。
    ///      原先在这里做的逐笔限价校验与两侧守恒**需要订单内容**（方向 + 限价），已随
    ///      `_verifyAllocation` 一起搬进 `PlaintextMatchVerifier`；`volume` 由
    ///      `matchVerifier.verifyMatch` 复算并返回（接口按 §3.1 保留该返回值），此处只做落账，
    ///      因此结算层不需要读订单内容——这也是验收判据 3 的机械化前提。
    function _applyFills(
        BatchSettlement calldata batch,
        uint256 /* volume */
    )
        private
    {
        uint256 n = batch.orderIds.length;
        bytes32[] memory filledIds = new bytes32[](batch.fills.length);
        uint256[] memory filledSolds = new uint256[](batch.fills.length);
        uint256 f;

        for (uint256 i = 0; i < n && f < batch.fills.length; i++) {
            if (batch.fills[f].orderId != batch.orderIds[i]) continue; // 未成交订单
            filledIds[f] = batch.fills[f].orderId;
            filledSolds[f] = batch.fills[f].amountSold;
            f++;
        }
        if (f != batch.fills.length) revert Errors.RecomputeMismatch();

        orderBook.settleBatch(filledIds, filledSolds, batch.solver);
    }
}
