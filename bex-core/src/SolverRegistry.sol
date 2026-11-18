// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";
import { Errors } from "./libraries/Errors.sol";
import { RiskParams } from "./libraries/Params.sol";
import { SafeTransfer } from "./libraries/SafeTransfer.sol";

/// @title SolverRegistry
/// @notice Solver registration, bonds, exposure, and slashing.
/// @dev Newly frozen interfaces and formulas in this batch (see docs/05 §7):
///      - `solverId = keccak256(abi.encode(operator))`: one operator address maps to one solver;
///      - Per-order cap = bond x 5% (500 bps); total exposure cap = bond x 50% (5000 bps);
///      - Bond must not fall below the floor after withdrawal, and no withdrawal at all while unsettled exposure exists;
///      - `settlement` is the only role that can change exposure and execute slashing (placeholder until the permission model is frozen);
///      - Slashed funds go to the `riskPool` (the challenger's share is pending freeze in P1-3);
///      - The per-order/total exposure ratios and minimum bond are **deploy-time parameters** (`RiskParams.Config`, with bounds and
///        the cross-invariant per-order ≤ total exposure); the first version's decided values (5% / 50%) are unchanged; see `docs/31` for registration;
///      - **Capacity ladder** (`docs/31` group C): after `UPGRADE_WINDOW_BLOCKS` consecutive blocks with no slashing, the per-order/total exposure
///        caps are multiplied by `UPGRADE_MULTIPLIER_BPS`; the default window of 0 = **off** (existing deployments behave unchanged).
contract SolverRegistry {
    using SafeTransfer for IERC20;

    /// @notice Per-order cap ratio (bps). Deploy-time parameter; first version's decided value is 500 (5%).
    uint256 public immutable MAX_SINGLE_ORDER_BPS;
    /// @notice Total exposure cap ratio (bps). Deploy-time parameter; first version's decided value is 5,000 (50%).
    uint256 public immutable MAX_TOTAL_EXPOSURE_BPS;
    /// @notice Capacity-ladder window (blocks); 0 = off (default).
    uint256 public immutable UPGRADE_WINDOW_BLOCKS;
    /// @notice Cap multiplier after the ladder upgrade (bps); 10,000 = no increase.
    uint256 public immutable UPGRADE_MULTIPLIER_BPS;
    uint256 public immutable GLOBAL_EXPOSURE_CAP;
    uint256 public immutable MAX_CONCURRENT_OPEN_EPOCHS;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable bondToken;
    address public immutable settlement;
    address public immutable riskPool;
    uint256 public immutable minBond;
    /// @notice Deployer: used only to bind the SLA slasher once (same shape as `CommitteeRegistry.bindSlasher`).
    address public immutable deployer;
    /// @notice SLA slasher (optional; unbound = `slashBySla` unavailable). Bound once, not replaceable.
    /// @dev Wording in `docs/39` §6, step 3, and the `docs/41` sign-off: an SLA breach needs a slashing channel **independent of settlement**;
    ///      when unbound/unwired, on-chain behavior is exactly as before (no new funds path is opened).
    address public slaSlasher;

    struct Solver {
        bytes32 pubKey;
        uint256 bond;
        uint256 exposure;
        bool registered;
        bool exitRequested;
        /// @dev Most recent "clean start": recorded as the current block at registration, and **reset on every actual slash** (the capacity-ladder criterion).
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

    /// @notice Deploy-time parameter validation and storage (out-of-range values revert at construction, see `RiskParams.validate`).
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

    /// @notice The currently active deploy-time risk parameters (operators, monitors, and reviewers read them here, docs/31 §10-5).
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

    // ------------------------------------------------------------ Registration and bonds

    /// @notice Register a solver and post the initial bond. `solverId` is derived from the caller's address.
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

    /// @notice Top up bond.
    function depositBond(uint256 amount) external nonReentrant {
        bytes32 solverId = _requireSolver(msg.sender);
        if (amount == 0) revert Errors.InvalidOrder();

        _solvers[solverId].bond += amount;
        bondToken.safeTransferFromExact(msg.sender, address(this), amount);
        emit BondDeposited(solverId, amount);
    }

    /// @notice Request exit. Not allowed while unsettled exposure exists.
    function requestExit() external {
        bytes32 solverId = _requireSolver(msg.sender);
        if (_solvers[solverId].exposure != 0) revert Errors.SolverExposureExceeded();

        _solvers[solverId].exitRequested = true;
        emit ExitRequested(solverId);
    }

    /// @notice Withdraw bond. Hard constraints: no unsettled exposure, exit requested, and bond stays at or above the floor after withdrawal.
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

    // ------------------------------------------------------------ Exposure and slashing

    /// @notice Open exposure. Settlement contract only; checks both the per-order cap and the total exposure cap.
    function openExposure(bytes32 solverId, uint256 amount) external onlySettlement {
        _openExposure(solverId, amount);
    }

    function openExposure(bytes32 solverId, uint64 epoch, uint256 amount) external onlySettlement {
        _openExposure(solverId, amount);
        if (_globalReservation[epoch] != bytes32(0)) revert Errors.GlobalReservationMismatch();
        if (globalOpenEpochs >= MAX_CONCURRENT_OPEN_EPOCHS) revert Errors.GlobalConcurrentEpochLimit();
        // Compare before subtracting: even if a corrupt stored state puts used allowance above the cap, fail closed
        // instead of triggering a meaningless panic at the subtraction.
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

    /// @notice Close exposure. Settlement contract only.
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

    /// @notice Slash. Settlement contract only; slashed funds go to the risk pool.
    function slash(bytes32 solverId, uint256 amount, bytes32 reason) external onlySettlement nonReentrant {
        _applySlash(solverId, amount, reason);
    }

    /// @notice Bind the SLA slasher once (called by the deployer; not replaceable, not unbindable).
    function bindSlaSlasher(address slaSlasher_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (slaSlasher != address(0)) revert Errors.AlreadySet();
        if (slaSlasher_ == address(0)) revert Errors.InvalidOrder();
        slaSlasher = slaSlasher_;
        emit SlaSlasherBound(slaSlasher_);
    }

    /// @notice **SLA-breach slashing** (the second channel, alongside the settlement path): only the bound SLA slasher may call it.
    /// @dev Shares the cap/reset logic with `slash`; the amount and trigger come from the off-chain SLA decision
    ///      (`tools/solver/sla_bond.py`, off by default); on-chain it only guarantees "never slash beyond the balance + reset the clean start".
    function slashBySla(bytes32 solverId, uint256 amount, bytes32 reason) external onlySlaSlasher nonReentrant {
        _applySlash(solverId, amount, reason);
    }

    modifier onlySlaSlasher() {
        if (msg.sender != slaSlasher || slaSlasher == address(0)) revert Errors.NotSlasher();
        _;
    }

    /// @dev Shared slash implementation: capped by balance, resets the capacity ladder's "clean start", slashed funds go to the risk pool.
    function _applySlash(bytes32 solverId, uint256 amount, bytes32 reason) private {
        Solver storage solver = _solvers[solverId];
        if (!solver.registered) revert Errors.NotRegistered();

        uint256 penalty = amount > solver.bond ? solver.bond : amount;
        solver.bond -= penalty;

        if (penalty != 0) {
            // Capacity ladder: any actual slash resets the "clean start".
            solver.cleanSinceBlock = block.number;
            emit CleanStreakReset(solverId, block.number);
            bondToken.safeTransferExact(riskPool, penalty);
        }
        emit Slashed(solverId, penalty, reason);
    }

    // ------------------------------------------------------------ Queries

    /// @notice Current exposure.
    function exposure(bytes32 solverId) external view returns (uint256) {
        return _solvers[solverId].exposure;
    }

    /// @notice Bond balance.
    function bondOf(bytes32 solverId) external view returns (uint256) {
        return _solvers[solverId].bond;
    }

    /// @notice Whether the capacity-ladder window is complete (no slashing in a row). Always false when the window is 0 (off).
    function upgradeEligible(bytes32 solverId) public view returns (bool) {
        if (UPGRADE_WINDOW_BLOCKS == 0) return false;
        Solver storage solver = _solvers[solverId];
        if (!solver.registered || solver.exitRequested) return false;
        return block.number >= solver.cleanSinceBlock + UPGRADE_WINDOW_BLOCKS;
    }

    /// @notice Currently applicable cap multiplier (bps): window complete -> `UPGRADE_MULTIPLIER_BPS`, otherwise 10,000.
    function riskMultiplierBps(bytes32 solverId) public view returns (uint256) {
        return upgradeEligible(solverId) ? UPGRADE_MULTIPLIER_BPS : BPS_DENOMINATOR;
    }

    /// @notice Per-order cap = bond x per-order ratio x (multiplier when the capacity window is complete).
    function maxSingleOrderSize(bytes32 solverId) public view returns (uint256) {
        // Self-review F1: divide before multiplying, so `bond × bps × multiplier` cannot overflow an intermediate value (bond has no cap,
        // and neither does `depositBond`). With the multiplier off (10,000), the result is **bit-for-bit identical** to the old formula;
        // when on with a multiplier other than 2.0x, it may be 1 smallest unit lower than the old formula (the more conservative direction).
        uint256 base = _solvers[solverId].bond * MAX_SINGLE_ORDER_BPS / BPS_DENOMINATOR;
        return base * riskMultiplierBps(solverId) / BPS_DENOMINATOR;
    }

    /// @notice Total exposure cap = bond x total exposure ratio x (multiplier when the capacity window is complete).
    function maxTotalExposure(bytes32 solverId) public view returns (uint256) {
        uint256 base = _solvers[solverId].bond * MAX_TOTAL_EXPOSURE_BPS / BPS_DENOMINATOR;
        return base * riskMultiplierBps(solverId) / BPS_DENOMINATOR;
    }

    /// @notice Remaining exposure capacity.
    function availableBond(bytes32 solverId) external view returns (uint256) {
        uint256 cap = maxTotalExposure(solverId);
        uint256 used = _solvers[solverId].exposure;
        return cap > used ? cap - used : 0;
    }

    function isRegistered(bytes32 solverId) external view returns (bool) {
        return _solvers[solverId].registered;
    }

    // ------------------------------------------------------------ Internal

    function _requireSolver(address operator) private view returns (bytes32 solverId) {
        solverId = solverIdOf[operator];
        if (solverId == bytes32(0) || !_solvers[solverId].registered) revert Errors.NotRegistered();
    }
}
