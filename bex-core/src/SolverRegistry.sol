// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";
import { Errors } from "./libraries/Errors.sol";
import { RiskParams } from "./libraries/Params.sol";
import { SafeTransfer } from "./libraries/SafeTransfer.sol";

/// @title SolverRegistry
/// @notice 求解者注册、保证金、敞口与罚没。
/// @dev 本批新钉死的接口与公式（见 docs/05 第七节）：
///      - `solverId = keccak256(abi.encode(operator))`，一个运营地址对应一个求解者；
///      - 单笔上限 = 保证金 × 5%（500 bps）；总敞口上限 = 保证金 × 50%（5000 bps）；
///      - 提取后保证金不得低于下限，且存在未结算敞口时一律不可提取；
///      - `settlement` 是唯一可变更敞口与执行罚没的角色（占位，待权限模型冻结）；
///      - 罚没金转入 `riskPool`（挑战者分成的部分待 P1-3 冻结）；
///      - 单笔/总敞口比例与最低保证金是**部署期参数**（`RiskParams.Config`，带上下界与
///        单笔 ≤ 总敞口的交叉不变量），第一版决策值（5% / 50%）不变；登记见 `docs/31`；
///      - **扩容阶梯**（`docs/31` C 组）：连续 `UPGRADE_WINDOW_BLOCKS` 块无罚没即把单笔/总敞口
///        上限乘 `UPGRADE_MULTIPLIER_BPS`；默认窗口 0 = **关闭**（既有部署行为不变）。
contract SolverRegistry {
    using SafeTransfer for IERC20;

    /// @notice 单笔上限比例（bps）。部署期参数；第一版决策值 500（5%）。
    uint256 public immutable MAX_SINGLE_ORDER_BPS;
    /// @notice 总敞口上限比例（bps）。部署期参数；第一版决策值 5,000（50%）。
    uint256 public immutable MAX_TOTAL_EXPOSURE_BPS;
    /// @notice 扩容阶梯窗口（区块）；0 = 关闭（默认）。
    uint256 public immutable UPGRADE_WINDOW_BLOCKS;
    /// @notice 扩容后的限额倍数（bps）；10,000 = 不提额。
    uint256 public immutable UPGRADE_MULTIPLIER_BPS;
    uint256 public immutable GLOBAL_EXPOSURE_CAP;
    uint256 public immutable MAX_CONCURRENT_OPEN_EPOCHS;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable bondToken;
    address public immutable settlement;
    address public immutable riskPool;
    uint256 public immutable minBond;
    /// @notice 部署者：仅用于一次性绑定 SLA 罚没方（与 `CommitteeRegistry.bindSlasher` 同形）。
    address public immutable deployer;
    /// @notice SLA 罚没方（可选；未绑定 = `slashBySla` 不可用）。一次性绑定，不可更换。
    /// @dev 口径见 `docs/39` §六 第 3 步与 `docs/41` 签字单：SLA 违约需要一条**独立于结算**的罚没通道；
    ///      未绑定/未接线时链上行为与之前完全一致（没有任何新资金路径被打开）。
    address public slaSlasher;

    struct Solver {
        bytes32 pubKey;
        uint256 bond;
        uint256 exposure;
        bool registered;
        bool exitRequested;
        /// @dev 最近一次"清白起点"：注册时记为当块，**每次实际罚没清零重算**（扩容阶梯的判据）。
        uint256 cleanSinceBlock;
    }

    mapping(bytes32 => Solver) private _solvers;
    mapping(address => bytes32) public solverIdOf;
    uint256 public globalExposure;
    uint256 public globalOpenEpochs;
    mapping(uint64 => bytes32) private _globalReservation;

    uint256 private _reentrancyLock = 1;

    event SolverRegistered(bytes32 indexed solverId, address indexed operator, bytes32 pubKey, uint256 bond);
    event BondDeposited(bytes32 indexed solverId, uint256 amount);
    event ExitRequested(bytes32 indexed solverId);
    event BondWithdrawn(bytes32 indexed solverId, uint256 amount);
    event ExposureOpened(bytes32 indexed solverId, uint256 amount, uint256 totalExposure);
    event ExposureClosed(bytes32 indexed solverId, uint256 amount, uint256 totalExposure);
    event GlobalExposureOpened(
        uint64 indexed epoch, bytes32 indexed solverId, uint256 hold, uint256 exposure, uint256 openEpochs
    );
    event GlobalExposureClosed(
        uint64 indexed epoch, bytes32 indexed solverId, uint256 hold, uint256 exposure, uint256 openEpochs
    );
    event Slashed(bytes32 indexed solverId, uint256 amount, bytes32 reason);
    event SlaSlasherBound(address indexed slaSlasher);
    event CleanStreakReset(bytes32 indexed solverId, uint256 cleanSinceBlock);

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert Errors.Reentrant();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    modifier onlySettlement() {
        if (msg.sender != settlement) revert Errors.NotSettlement();
        _;
    }

    /// @notice 部署期参数校验与落地（越界在构造期 revert，见 `RiskParams.validate`）。
    constructor(IERC20 bondToken_, address settlement_, address riskPool_, RiskParams.Config memory params_) {
        if (address(bondToken_) == address(0) || settlement_ == address(0) || riskPool_ == address(0)) {
            revert Errors.InvalidOrder();
        }
        RiskParams.validate(params_);
        bondToken = bondToken_;
        settlement = settlement_;
        riskPool = riskPool_;
        minBond = params_.minBond;
        MAX_SINGLE_ORDER_BPS = params_.singleOrderBps;
        MAX_TOTAL_EXPOSURE_BPS = params_.totalExposureBps;
        UPGRADE_WINDOW_BLOCKS = params_.upgradeWindowBlocks;
        UPGRADE_MULTIPLIER_BPS = params_.upgradeMultiplierBps;
        GLOBAL_EXPOSURE_CAP = params_.globalExposureCap;
        MAX_CONCURRENT_OPEN_EPOCHS = params_.maxConcurrentOpenEpochs;
        deployer = msg.sender;
    }

    /// @notice 当前生效的部署期风险参数（运维/监控/审计从这里读，docs/31 第十节-5）。
    function params() external view returns (RiskParams.Config memory) {
        return RiskParams.Config({
            minBond: minBond,
            singleOrderBps: MAX_SINGLE_ORDER_BPS,
            totalExposureBps: MAX_TOTAL_EXPOSURE_BPS,
            upgradeWindowBlocks: UPGRADE_WINDOW_BLOCKS,
            upgradeMultiplierBps: UPGRADE_MULTIPLIER_BPS,
            globalExposureCap: GLOBAL_EXPOSURE_CAP,
            maxConcurrentOpenEpochs: MAX_CONCURRENT_OPEN_EPOCHS
        });
    }

    // ------------------------------------------------------------ 注册与保证金

    /// @notice 注册求解者并缴纳初始保证金。`solverId` 由调用者地址派生。
    function register(bytes32 pubKey, uint256 bond) external nonReentrant {
        if (solverIdOf[msg.sender] != bytes32(0)) revert Errors.AlreadyRegistered();
        if (bond < minBond) revert Errors.SolverBondInsufficient();

        bytes32 solverId = keccak256(abi.encode(msg.sender));
        solverIdOf[msg.sender] = solverId;
        _solvers[solverId] = Solver({
            pubKey: pubKey,
            bond: bond,
            exposure: 0,
            registered: true,
            exitRequested: false,
            cleanSinceBlock: block.number
        });

        bondToken.safeTransferFromExact(msg.sender, address(this), bond);
        emit SolverRegistered(solverId, msg.sender, pubKey, bond);
    }

    /// @notice 追加保证金。
    function depositBond(uint256 amount) external nonReentrant {
        bytes32 solverId = _requireSolver(msg.sender);
        if (amount == 0) revert Errors.InvalidOrder();

        _solvers[solverId].bond += amount;
        bondToken.safeTransferFromExact(msg.sender, address(this), amount);
        emit BondDeposited(solverId, amount);
    }

    /// @notice 申请退出。存在未结算敞口时不得申请。
    function requestExit() external {
        bytes32 solverId = _requireSolver(msg.sender);
        if (_solvers[solverId].exposure != 0) revert Errors.SolverExposureExceeded();

        _solvers[solverId].exitRequested = true;
        emit ExitRequested(solverId);
    }

    /// @notice 提取保证金。硬约束：无未结算敞口、已申请退出、提取后不低于下限。
    function withdrawBond(uint256 amount) external nonReentrant {
        bytes32 solverId = _requireSolver(msg.sender);
        Solver storage solver = _solvers[solverId];

        if (solver.exposure != 0) revert Errors.SolverExposureExceeded();
        if (!solver.exitRequested) revert Errors.ExitNotRequested();
        if (amount == 0 || amount > solver.bond) revert Errors.SolverBondInsufficient();

        uint256 remaining = solver.bond - amount;
        if (remaining != 0 && remaining < minBond) revert Errors.SolverBondInsufficient();

        solver.bond = remaining;
        if (remaining == 0) {
            solver.registered = false;
            solver.exitRequested = false;
            solverIdOf[msg.sender] = bytes32(0);
        }

        bondToken.safeTransferExact(msg.sender, amount);
        emit BondWithdrawn(solverId, amount);
    }

    // ------------------------------------------------------------ 敞口与罚没

    /// @notice 开立敞口。仅结算合约可调用；同时校验单笔上限与总敞口上限。
    function openExposure(bytes32 solverId, uint256 amount) external onlySettlement {
        _openExposure(solverId, amount);
    }

    function openExposure(bytes32 solverId, uint64 epoch, uint256 amount) external onlySettlement {
        _openExposure(solverId, amount);
        if (_globalReservation[epoch] != bytes32(0)) revert Errors.GlobalReservationMismatch();
        if (globalOpenEpochs >= MAX_CONCURRENT_OPEN_EPOCHS) revert Errors.GlobalConcurrentEpochLimit();
        // 先比较再相减：即使错误的存储状态让已用额度高于 cap，也要 fail-closed，
        // 而不是在减法处触发无语义的 panic。
        if (globalExposure > GLOBAL_EXPOSURE_CAP || amount > GLOBAL_EXPOSURE_CAP - globalExposure) {
            revert Errors.GlobalExposureExceeded();
        }
        globalExposure += amount;
        globalOpenEpochs += 1;
        _globalReservation[epoch] = keccak256(abi.encode(solverId, amount));
        emit GlobalExposureOpened(epoch, solverId, amount, globalExposure, globalOpenEpochs);
    }

    function _openExposure(bytes32 solverId, uint256 amount) private {
        Solver storage solver = _solvers[solverId];
        if (!solver.registered) revert Errors.NotRegistered();
        if (amount == 0) revert Errors.InvalidOrder();
        if (amount > maxSingleOrderSize(solverId)) revert Errors.SolverExposureExceeded();

        uint256 total = solver.exposure + amount;
        if (total > maxTotalExposure(solverId)) revert Errors.SolverExposureExceeded();

        solver.exposure = total;
        emit ExposureOpened(solverId, amount, total);
    }

    /// @notice 结清敞口。仅结算合约可调用。
    function closeExposure(bytes32 solverId, uint256 amount) external onlySettlement {
        _closeExposure(solverId, amount);
    }

    function closeExposure(bytes32 solverId, uint64 epoch, uint256 amount) external onlySettlement {
        bytes32 expected = keccak256(abi.encode(solverId, amount));
        if (_globalReservation[epoch] != expected) revert Errors.GlobalReservationMismatch();
        _closeExposure(solverId, amount);
        delete _globalReservation[epoch];
        globalExposure -= amount;
        globalOpenEpochs -= 1;
        emit GlobalExposureClosed(epoch, solverId, amount, globalExposure, globalOpenEpochs);
    }

    function _closeExposure(bytes32 solverId, uint256 amount) private {
        Solver storage solver = _solvers[solverId];
        if (amount > solver.exposure) revert Errors.SolverExposureExceeded();

        solver.exposure -= amount;
        emit ExposureClosed(solverId, amount, solver.exposure);
    }

    function globalReservationOf(uint64 epoch) external view returns (bytes32) {
        return _globalReservation[epoch];
    }

    /// @notice 罚没。仅结算合约可调用；罚没金转入风险池。
    function slash(bytes32 solverId, uint256 amount, bytes32 reason) external onlySettlement nonReentrant {
        _applySlash(solverId, amount, reason);
    }

    /// @notice 一次性绑定 SLA 罚没方（部署者调用；不可更换、不可解绑）。
    function bindSlaSlasher(address slaSlasher_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (slaSlasher != address(0)) revert Errors.AlreadySet();
        if (slaSlasher_ == address(0)) revert Errors.InvalidOrder();
        slaSlasher = slaSlasher_;
        emit SlaSlasherBound(slaSlasher_);
    }

    /// @notice **SLA 违约罚没**（与结算路径并列的第二条通道）：只有绑定的 SLA 罚没方可调用。
    /// @dev 与 `slash` 共用同一份封顶/清零逻辑；金额与触发条件由链下 SLA 判定给出
    ///      （`tools/solver/sla_bond.py`，默认关闭），链上只保证"不罚出余额 + 清零清白起点"。
    function slashBySla(bytes32 solverId, uint256 amount, bytes32 reason) external onlySlaSlasher nonReentrant {
        _applySlash(solverId, amount, reason);
    }

    modifier onlySlaSlasher() {
        if (msg.sender != slaSlasher || slaSlasher == address(0)) revert Errors.NotSlasher();
        _;
    }

    /// @dev 罚没的共用实现：按余额封顶、清零扩容阶梯的"清白起点"、罚没金进风险池。
    function _applySlash(bytes32 solverId, uint256 amount, bytes32 reason) private {
        Solver storage solver = _solvers[solverId];
        if (!solver.registered) revert Errors.NotRegistered();

        uint256 penalty = amount > solver.bond ? solver.bond : amount;
        solver.bond -= penalty;

        if (penalty != 0) {
            // 扩容阶梯：任何一次实际罚没都把"清白起点"清零重算
            solver.cleanSinceBlock = block.number;
            emit CleanStreakReset(solverId, block.number);
            bondToken.safeTransferExact(riskPool, penalty);
        }
        emit Slashed(solverId, penalty, reason);
    }

    // ------------------------------------------------------------ 查询

    /// @notice 当前敞口。
    function exposure(bytes32 solverId) external view returns (uint256) {
        return _solvers[solverId].exposure;
    }

    /// @notice 保证金余额。
    function bondOf(bytes32 solverId) external view returns (uint256) {
        return _solvers[solverId].bond;
    }

    /// @notice 是否已满扩容窗口（连续无罚没）。窗口为 0（关闭）时恒为 false。
    function upgradeEligible(bytes32 solverId) public view returns (bool) {
        if (UPGRADE_WINDOW_BLOCKS == 0) return false;
        Solver storage solver = _solvers[solverId];
        if (!solver.registered || solver.exitRequested) return false;
        return block.number >= solver.cleanSinceBlock + UPGRADE_WINDOW_BLOCKS;
    }

    /// @notice 当前适用的限额倍数（bps）：满窗口 → `UPGRADE_MULTIPLIER_BPS`，否则 10,000。
    function riskMultiplierBps(bytes32 solverId) public view returns (uint256) {
        return upgradeEligible(solverId) ? UPGRADE_MULTIPLIER_BPS : BPS_DENOMINATOR;
    }

    /// @notice 单笔订单上限 = 保证金 × 单笔比例 ×（满扩容窗口时的倍数）。
    function maxSingleOrderSize(bytes32 solverId) public view returns (uint256) {
        // 自审 F1：先除后乘，避免 `bond × bps × 倍数` 三连乘把中间值顶到溢出（保证金无上限，
        // `depositBond` 也不设上限）。倍数关闭时（10,000）结果与旧式**逐位一致**；
        // 开启且倍数非 2.0× 时可能比旧式少 1 个最小单位（更保守的方向）。
        uint256 base = _solvers[solverId].bond * MAX_SINGLE_ORDER_BPS / BPS_DENOMINATOR;
        return base * riskMultiplierBps(solverId) / BPS_DENOMINATOR;
    }

    /// @notice 总敞口上限 = 保证金 × 总敞口比例 ×（满扩容窗口时的倍数）。
    function maxTotalExposure(bytes32 solverId) public view returns (uint256) {
        uint256 base = _solvers[solverId].bond * MAX_TOTAL_EXPOSURE_BPS / BPS_DENOMINATOR;
        return base * riskMultiplierBps(solverId) / BPS_DENOMINATOR;
    }

    /// @notice 还可承接的敞口额度。
    function availableBond(bytes32 solverId) external view returns (uint256) {
        uint256 cap = maxTotalExposure(solverId);
        uint256 used = _solvers[solverId].exposure;
        return cap > used ? cap - used : 0;
    }

    function isRegistered(bytes32 solverId) external view returns (bool) {
        return _solvers[solverId].registered;
    }

    // ------------------------------------------------------------ 内部

    function _requireSolver(address operator) private view returns (bytes32 solverId) {
        solverId = solverIdOf[operator];
        if (solverId == bytes32(0) || !_solvers[solverId].registered) revert Errors.NotRegistered();
    }
}
