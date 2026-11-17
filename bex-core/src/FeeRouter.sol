// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title FeeRouter（费用层 v1：**接口与数学冻结，钱路关闭**）
/// @notice 设计单见 `docs/35-费用层设计单（批次三）.md`。本版只做三件事：
///         ① 冻结调用形状（`collect` 的 selector 与 `FeeCollected` 事件）；
///         ② 冻结分账数学（`quoteAt` 是唯一的取整实现，含"费向上、分账向下、余数归求解者"）；
///         ③ 冻结参数上下界，越界在**构造期** revert（与 `Params.sol` 同一纪律）。
///
/// @dev **本版不含任何转账路径**：`collect()` 一律 revert `FeeCollectionDisabled()`。
///      开收费（设计单 §八 第 3 步）是**一次需要审计的行为变更**，不是参数变更——
///      届时把 `collect()` 的体替换为"按 `quoteAt` 分账并转账"，selector 与事件不动。
///      这样做的目的：让"费率=0、收费开关关闭"成为**代码事实**而不是运维承诺。
///
/// @dev 边界纪律（`docs/20` §2.3 结算层不可知）：本合约**不依赖 Settlement/OrderBook**，
///      也不认识任何档位；费率由部署方按档位各部署一份（或按批次传入，见设计单 §四）。
contract FeeRouter {
    /// @dev 越界参数名进 revert reason，测试与运维可直接定位字段。
    error FeeConfigOutOfBounds(string name);
    /// @dev v1：钱路关闭。不返回 0、不静默跳过——调用方必须显式处理"收费未启用"。
    error FeeCollectionDisabled();

    struct Config {
        uint256 feeBps; // 费率（bps）。v1 必须为 0
        uint256 capBps; // 链上硬上限：`feeBps ≤ capBps ≤ 100`
        uint256 minFee; // 最低收费（计价代币最小单位）；与 bps 部分的差额**全额归求解者**
        uint256 solverBps; // 求解者分成（8000 = 80%）
        uint256 riskPoolBps; // 风险池分成（1500 = 15%）
        uint256 opsBps; // 运营分成（500 = 5%）
        address solver; // 求解者收款地址（v1 仅登记，不转账）
        address riskPool; // 风险池收款地址
        address ops; // 运营收款地址
    }

    /// @dev 一次收费的分解；`total == toSolver + toRiskPool + toOps`（设计单 §六 I2）。
    struct Split {
        uint256 total;
        uint256 toSolver;
        uint256 toRiskPool;
        uint256 toOps;
    }

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @dev 费率上限 1%（`docs/31` B 组：0–100 bp，分档单调不减）。
    uint256 internal constant CAP_BPS_MAX = 100;
    /// @dev 最低收费的绝对上限：1 USDT（6 位小数计价代币口径）。换精度需重算。
    uint256 internal constant MIN_FEE_MAX = 1_000_000;
    /// @dev 分账区间：求解者 50%–90%，风险池与运营各 ≤30%，三者合计恒为 100%。
    uint256 internal constant SOLVER_BPS_MIN = 5_000;
    uint256 internal constant SOLVER_BPS_MAX = 9_000;
    uint256 internal constant POOL_BPS_MAX = 3_000;

    uint256 public immutable FEE_BPS;
    uint256 public immutable CAP_BPS;
    uint256 public immutable MIN_FEE;
    uint256 public immutable SOLVER_BPS;
    uint256 public immutable RISK_POOL_BPS;
    uint256 public immutable OPS_BPS;
    address public immutable SOLVER;
    address public immutable RISK_POOL;
    address public immutable OPS;

    /// @notice 收费事件（v1 不会发出——钱路关闭；selector 冻结供将来的索引器与监控使用）。
    event FeeCollected(
        uint64 indexed epoch,
        bytes32 indexed orderId,
        uint256 fee,
        address indexed solver,
        uint256 toSolver,
        uint256 toRiskPool,
        uint256 toOps
    );

    constructor(Config memory config) {
        _validate(config);
        FEE_BPS = config.feeBps;
        CAP_BPS = config.capBps;
        MIN_FEE = config.minFee;
        SOLVER_BPS = config.solverBps;
        RISK_POOL_BPS = config.riskPoolBps;
        OPS_BPS = config.opsBps;
        SOLVER = config.solver;
        RISK_POOL = config.riskPool;
        OPS = config.ops;
    }

    // ------------------------------------------------------------ 只读

    /// @notice 部署期配置快照（运维/审计从链上读，不靠链下硬编码）。
    function config() external view returns (Config memory) {
        return Config({
            feeBps: FEE_BPS,
            capBps: CAP_BPS,
            minFee: MIN_FEE,
            solverBps: SOLVER_BPS,
            riskPoolBps: RISK_POOL_BPS,
            opsBps: OPS_BPS,
            solver: SOLVER,
            riskPool: RISK_POOL,
            ops: OPS
        });
    }

    /// @notice 按**当前费率**报一次收费分解（v1 恒为全 0）。
    function quote(uint256 notional) external view returns (Split memory) {
        return quoteAt(notional, FEE_BPS);
    }

    /// @notice 分账数学的**唯一实现**（开收费后 `collect()` 复用它）。
    /// @dev 取整方向（设计单 §六 I8）：费用部分**向上**取整、分账**向下**取整，
    ///      余数与最低收费差额**全归求解者**——保证 `total` 恒等于三项之和、且协议不欠款。
    function quoteAt(uint256 notional, uint256 feeBps) public view returns (Split memory) {
        if (feeBps > CAP_BPS) revert FeeConfigOutOfBounds("feeBps");
        // 收费关闭（v1 的部署期约束就是 `feeBps == 0`）→ 明确返回全 0：
        // 最低收费是"有费用时的下限"，不是"零费率也要收"。否则关费率反而变成强制收费。
        if (feeBps == 0) return Split({ total: 0, toSolver: 0, toRiskPool: 0, toOps: 0 });
        // 向上取整：notional × feeBps / 1e4
        uint256 feeFromBps = _ceilDiv(notional * feeBps, BPS_DENOMINATOR);
        uint256 total = feeFromBps > MIN_FEE ? feeFromBps : MIN_FEE;
        uint256 toRiskPool = (feeFromBps * RISK_POOL_BPS) / BPS_DENOMINATOR;
        uint256 toOps = (feeFromBps * OPS_BPS) / BPS_DENOMINATOR;
        // 余数（含最低收费与 bps 部分的差额）全归求解者
        uint256 toSolver = total - toRiskPool - toOps;
        return Split({ total: total, toSolver: toSolver, toRiskPool: toRiskPool, toOps: toOps });
    }

    /// @notice 收费入口：**v1 一律拒绝**（钱路关闭）。
    /// @dev 开收费时替换本函数体（按 `quoteAt` 分账并转账）；selector 与 `FeeCollected` 事件不变。
    function collect(uint64, bytes32, uint256, address) external pure {
        revert FeeCollectionDisabled();
    }

    // ------------------------------------------------------------ 内部

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : ((numerator - 1) / denominator) + 1;
    }

    function _validate(Config memory config) private pure {
        // 费率与硬上限：v1 要求 feeBps == 0（收费开关默认关，见设计单 §四）
        if (config.feeBps != 0) revert FeeConfigOutOfBounds("feeBps!=0");
        if (config.capBps == 0 || config.capBps > CAP_BPS_MAX) revert FeeConfigOutOfBounds("capBps");
        if (config.minFee > MIN_FEE_MAX) revert FeeConfigOutOfBounds("minFee");
        // 分账：三项合计恒 100%，单项区间见常量注释
        if (config.solverBps < SOLVER_BPS_MIN || config.solverBps > SOLVER_BPS_MAX) {
            revert FeeConfigOutOfBounds("solverBps");
        }
        if (config.riskPoolBps > POOL_BPS_MAX) revert FeeConfigOutOfBounds("riskPoolBps");
        if (config.opsBps > POOL_BPS_MAX) revert FeeConfigOutOfBounds("opsBps");
        if (config.solverBps + config.riskPoolBps + config.opsBps != BPS_DENOMINATOR) {
            revert FeeConfigOutOfBounds("split!=100%");
        }
        // 收款人：非零、互不相同（重复会让分账语义含糊）
        if (
            config.solver == address(0) || config.riskPool == address(0) || config.ops == address(0)
                || config.solver == config.riskPool || config.solver == config.ops || config.riskPool == config.ops
        ) {
            revert FeeConfigOutOfBounds("recipient");
        }
    }
}
