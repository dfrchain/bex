// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title FeeRouter (fee layer v1: **frozen interface and math, money path closed**)
/// @notice See the design note `docs/35-fee-layer-design-note-(batch-3).md`. This version does only three things:
///         (1) Freeze the call shape (the `collect` selector and the `FeeCollected` event);
///         (2) Freeze the split math (`quoteAt` is the only rounding implementation: "fees round up, splits round down, remainder goes to the solver");
///         (3) Freeze the parameter bounds; out-of-range values revert at **construction time** (same discipline as `Params.sol`).
///
/// @dev **This version contains no transfer path at all**: `collect()` always reverts with `FeeCollectionDisabled()`.
///      Enabling fees (design note §8, step 3) is a **behavior change that needs review**, not a parameter change —
///      When that happens, replace the body of `collect()` with "split and transfer per `quoteAt`", leaving the selector and event untouched.
///      The point: "fee rate = 0, fee switch off" becomes a **fact in code**, not an operational promise.
///
/// @dev Boundary discipline (`docs/20` §2.3, settlement-layer agnosticism): this contract does **not depend on Settlement/OrderBook**,
///      and knows no tiers; the deployer deploys one fee schedule per tier (or passes one per batch, see design note §4).
contract FeeRouter {
    /// @dev Out-of-range parameter names go into the revert reason, so tests and operators can pinpoint the field directly.
    error FeeConfigOutOfBounds(string name);
    /// @dev v1: money path closed. It does not return 0 or silently skip — callers must explicitly handle "fees not enabled".
    error FeeCollectionDisabled();

    struct Config {
        uint256 feeBps; // Fee rate (bps). Must be 0 in v1
        uint256 capBps; // On-chain hard cap: `feeBps ≤ capBps ≤ 100`
        uint256 minFee; // Minimum fee (smallest unit of the pricing token); any shortfall vs the bps part goes **entirely to the solver**
        uint256 solverBps; // Solver share (8000 = 80%)
        uint256 riskPoolBps; // Risk pool share (1500 = 15%)
        uint256 opsBps; // Ops share (500 = 5%)
        address solver; // Solver payout address (v1 only records it, no transfers)
        address riskPool; // Risk pool payout address
        address ops; // Ops payout address
    }

    /// @dev Breakdown of a single fee; `total == toSolver + toRiskPool + toOps` (design note §6, I2).
    struct Split {
        uint256 total;
        uint256 toSolver;
        uint256 toRiskPool;
        uint256 toOps;
    }

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @dev Fee-rate cap of 1% (`docs/31` group B: 0–100 bp, non-decreasing across tiers).
    uint256 internal constant CAP_BPS_MAX = 100;
    /// @dev Absolute cap on the minimum fee: 1 USDT (6-decimal pricing-token terms). Recompute if the precision changes.
    uint256 internal constant MIN_FEE_MAX = 1_000_000;
    /// @dev Split ranges: solver 50%–90%, risk pool and ops each ≤30%, the three always summing to 100%.
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

    /// @notice Fee event (never emitted in v1 — money path closed; selector frozen for future indexers and monitoring).
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

    // ------------------------------------------------------------ Read-only

    /// @notice Deploy-time config snapshot (operators and reviewers read it on-chain instead of hardcoding values off-chain).
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

    /// @notice Quote one fee breakdown at the **current fee rate** (always all zeros in v1).
    function quote(uint256 notional) external view returns (Split memory) {
        return quoteAt(notional, FEE_BPS);
    }

    /// @notice The **only implementation** of the split math (`collect()` reuses it once fees are enabled).
    /// @dev Rounding directions (design note §6, I8): the fee part rounds **up**, splits round **down**,
    ///      and the remainder plus any minimum-fee shortfall goes **entirely to the solver** — so `total` always equals the sum of the three parts and the protocol never owes anything.
    function quoteAt(uint256 notional, uint256 feeBps) public view returns (Split memory) {
        if (feeBps > CAP_BPS) revert FeeConfigOutOfBounds("feeBps");
        // Fees disabled (the v1 deploy-time constraint is `feeBps == 0`) → explicitly return all zeros:
        // The minimum fee is a floor "when there is a fee", not "charge even at a zero rate". Otherwise turning the rate off would become a forced charge.
        if (feeBps == 0) return Split({ total: 0, toSolver: 0, toRiskPool: 0, toOps: 0 });
        // Round up: notional × feeBps / 1e4
        uint256 feeFromBps = _ceilDiv(notional * feeBps, BPS_DENOMINATOR);
        uint256 total = feeFromBps > MIN_FEE ? feeFromBps : MIN_FEE;
        uint256 toRiskPool = (feeFromBps * RISK_POOL_BPS) / BPS_DENOMINATOR;
        uint256 toOps = (feeFromBps * OPS_BPS) / BPS_DENOMINATOR;
        // Remainder (including the shortfall between the minimum fee and the bps part) goes entirely to the solver
        uint256 toSolver = total - toRiskPool - toOps;
        return Split({ total: total, toSolver: toSolver, toRiskPool: toRiskPool, toOps: toOps });
    }

    /// @notice Fee entry point: **always rejected in v1** (money path closed).
    /// @dev When fees are enabled, replace this function body (split and transfer per `quoteAt`); the selector and the `FeeCollected` event stay unchanged.
    function collect(uint64, bytes32, uint256, address) external pure {
        revert FeeCollectionDisabled();
    }

    // ------------------------------------------------------------ Internal

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : ((numerator - 1) / denominator) + 1;
    }

    function _validate(Config memory config) private pure {
        // Fee rate and hard cap: v1 requires feeBps == 0 (fee switch off by default, see design note §4)
        if (config.feeBps != 0) revert FeeConfigOutOfBounds("feeBps!=0");
        if (config.capBps == 0 || config.capBps > CAP_BPS_MAX) revert FeeConfigOutOfBounds("capBps");
        if (config.minFee > MIN_FEE_MAX) revert FeeConfigOutOfBounds("minFee");
        // Splits: the three parts always sum to 100%; per-part ranges are in the constant comments
        if (config.solverBps < SOLVER_BPS_MIN || config.solverBps > SOLVER_BPS_MAX) {
            revert FeeConfigOutOfBounds("solverBps");
        }
        if (config.riskPoolBps > POOL_BPS_MAX) revert FeeConfigOutOfBounds("riskPoolBps");
        if (config.opsBps > POOL_BPS_MAX) revert FeeConfigOutOfBounds("opsBps");
        if (config.solverBps + config.riskPoolBps + config.opsBps != BPS_DENOMINATOR) {
            revert FeeConfigOutOfBounds("split!=100%");
        }
        // Payees: non-zero and all distinct (duplicates would make the split semantics ambiguous)
        if (
            config.solver == address(0) || config.riskPool == address(0) || config.ops == address(0)
                || config.solver == config.riskPool || config.solver == config.ops || config.riskPool == config.ops
        ) {
            revert FeeConfigOutOfBounds("recipient");
        }
    }
}
