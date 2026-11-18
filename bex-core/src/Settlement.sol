// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IAttestationVerifier } from "./interfaces/IAttestationVerifier.sol";
import { IMatchVerifier } from "./interfaces/IMatchVerifier.sol";
import { IOrderBook } from "./interfaces/IOrderBook.sol";
import { Errors } from "./libraries/Errors.sol";
import { SolverRegistry } from "./SolverRegistry.sol";
import { BatchSettlement, Order } from "./types/BexTypes.sol";

/// @title Settlement
/// @notice Validate receipts and the settlement window, post fills, and handle refunds. **Does not recompute match results itself**:
///         match validity is delegated to the per-tier `IMatchVerifier` (plaintext tier = `PlaintextMatchVerifier`),
///         so the settlement layer reads no order contents at all (see `docs/09-tier-reserved-interface-spec.md` §2–3).
/// @dev The check order decides which error code each attack hits:
///      1. Chain ID binding -> WrongChain
///      2. Whether the digest was already consumed -> DigestAlreadyConsumed
///      3. Whether the same batch was already settled -> MultiplePrices
///      4. Whether the batch is closed -> EpochClosed
///      5. Set commitment and trading-pair definition -> OrderSetMismatch / InvalidOrder
///      6. Match validity -> decided by `matchVerifier.verifyMatch` (the plaintext tier reports OrderSetMismatch /
///         PayloadNotPriceOrdered / RecomputeMismatch / BelowUserLimit)
///      7. Settlement window -> InvalidOrder / EpochClosed (note: the payload `deadline` out-of-window check runs
///         **after** `matchVerifier.verifyMatch`, so a tier's own error codes (e.g. RevealExpired in the sealed tier)
///         surface first; audit round 8, L-02, records this order, and the comment matches the implementation)
///      8. Solver threshold -> NotRegistered / SolverBondInsufficient
///      9. Receipt signatures -> AttestationInvalid
contract Settlement {
    bytes32 private constant SETTLEMENT_DOMAIN = keccak256("BEX_SETTLEMENT");

    IAttestationVerifier public immutable verifier;
    /// @notice The order-book dependency is now an interface: the plaintext and sealed tiers share this settlement contract (see the `IOrderBook` comments).
    IOrderBook public immutable orderBook;
    /// @notice Match-validity verifier: implemented per tier. The settlement layer only talks to it via `verifyMatch` (tier isolation lives at deploy time).
    IMatchVerifier public immutable matchVerifier;
    /// @notice Deployer: used only to bind `SolverRegistry` once (same binding pattern as OrderBook).
    address public immutable deployer;
    /// @notice Solver registry: once bound, settlement checks "registered with sufficient bond" first; if unbound (address(0)), the check is skipped.
    SolverRegistry public solverRegistry;
    /// @notice Batch -> the solver dispatched for it (on-chain dispatch bookkeeping, docs/20).
    event SolverAllowedSet(address indexed solver, bool allowed);

    mapping(uint64 => address) public dispatchedSolver;
    /// @notice Solver allowlist (RT-15, red-team freeze-1): the first version uses **protocol-operated solvers** (docs/12 §5.2),
    ///         because without an allowlist, any newly registered solver could grab an epoch's dispatch slot with one `dispatch` call,
    ///         dragging that batch to a timeout refund (users are unharmed, but the batch is killed). Only `deployer` (the operator) may maintain it.
    mapping(address => bool) public solverAllowed;
    /// @notice Monotonic emergency revocation generation for all historical
    ///         obligations of a solver. Reauthorization never revives them.
    mapping(address => uint256) public solverAuthorizationGeneration;
    /// @dev **Exposure locked at dispatch time** (third-round supplementary review A): it must be recorded at dispatch,
    ///      otherwise recomputing `maxSingleOrderSize` at settlement/timeout release would grow if the solver tops up bond in between,
    ///      making the `closeExposure` amount mismatch -> the batch and bond get locked forever.
    mapping(uint64 => uint256) public dispatchHold;
    /// @notice Slash controller (D-4: triggered by multisig + timelock in the first version). Only it may call `slashSolver`.
    address public slashController;

    mapping(bytes32 => bool) private _consumedDigest;
    /// @dev RT-4 (red-team freeze-1): digest -> the epoch in which it was consumed. `settledDigest` only says "it was consumed",
    ///      and cross-epoch anchoring needs to know "which batch this digest belongs to".
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

    /// @notice Whether `SolverRegistry` must be bound before settling (default true).
    /// @dev Production and testnet deployments must keep this true; local drills can turn it off once via `setRegistryRequired(false)`.
    bool private _registryRequired = true;

    function registryRequired() external view returns (bool) {
        return _registryRequired;
    }

    /// @notice The deployer may **once** turn off the "registry must be bound" requirement (local drills only).
    function setRegistryRequired(bool required) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (!_registryRequired) revert Errors.AlreadySet();
        // R4-4: turning off the gate is **only allowed on a local chain** (for unit tests/drills), so it cannot be disabled by mistake on a production deployment
        if (!required) {
            require(block.chainid == 31337 || block.chainid == 31338, "registry opt-out is local-only");
        }
        _registryRequired = required;
        emit RegistryRequirementChanged(required);
    }

    /// @notice Bind the solver registry once (audit M-2). Immutable after binding; no upgradeable proxy is introduced.
    function bindSolverRegistry(SolverRegistry registry_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (address(registry_) == address(0)) revert Errors.InvalidOrder(); // M-4: the zero address would permanently close the gate
        if (address(solverRegistry) != address(0)) revert Errors.AlreadySet();
        solverRegistry = registry_;
        emit SolverRegistryBound(address(registry_));
    }

    /// @notice **On-chain dispatch** (docs/20): claim a batch after close and before the deadline, and lock that batch's exposure.
    /// @dev Dispatch happens before settlement, when the chain does not yet know the clearing price or volume, so each batch locks a conservative, predictable amount:
    ///      `maxSingleOrderSize(solverId)` (= bond x 5%); `maxTotalExposure` (x 50%) naturally caps in-flight batches at 10.
    ///      The lock takes effect automatically through the `exposure == 0` requirement in `SolverRegistry.withdrawBond`/`requestExit`:
    ///      **Between dispatch and settlement, a solver cannot withdraw bond** (third-round review M-2).
    /// @notice Maintain the solver allowlist (deployer/operator only). RT-15.
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
        // Third-round supplementary review B: dispatch must be initiated by the **dispatched solver themselves**, otherwise anyone could at zero cost
        // drain someone else's exposure allowance (denial of service). The first version uses protocol-operated solvers, so msg.sender == solver is required.
        if (msg.sender != solver) revert Errors.NotOrderOwner();
        // RT-15: allowlist admission (deny by default). The operator explicitly calls `setSolverAllowed` after deployment.
        if (!solverAllowed[solver]) revert Errors.NotRegistered();

        bytes32 solverId = solverRegistry.solverIdOf(solver);
        if (solverId == bytes32(0) || !solverRegistry.isRegistered(solverId)) revert Errors.NotRegistered();

        uint256 hold = solverRegistry.maxSingleOrderSize(solverId);
        dispatchedSolver[epoch] = solver;
        dispatchHold[epoch] = hold;
        solverRegistry.openExposure(solverId, epoch, hold);
        emit BatchDispatched(epoch, solver, hold);
    }

    /// @notice **Timeout exposure release**: anyone may call it once a batch is past its deadline height and unsettled (users still refund as normal).
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

    /// @notice Bind the slash controller once (D-4). Immutable after binding; if unbound, `slashSolver` is unavailable.
    /// @dev `SolverRegistry.slash` is `onlySettlement`, so "multisig + timelock" must go through the settlement contract.
    ///      Before that, slashing has **no reachable path on-chain** (the D-4 TODO in `docs/19-sign-off-proposal` §3).
    function bindSlashController(address controller_) external {
        if (msg.sender != deployer) revert Errors.NotDeployer();
        if (controller_ == address(0)) revert Errors.InvalidOrder();
        if (slashController != address(0)) revert Errors.AlreadySet();
        // Audit round 8, H-01/L-03: the controller must be a **contract** (multisig/timelock) and must not be bound to an EOA —
        // otherwise "multisig + delay" silently degrades to single-key control.
        if (controller_.code.length == 0) revert Errors.InvalidOrder();
        slashController = controller_;
        emit SlashControllerBound(controller_);
    }

    /// @notice Slash a solver (D-4: triggered by multisig + timelock). Only `slashController` may call it.
    /// @dev The deduction cap is enforced by `SolverRegistry.slash` (at most the solver's whole bond; nothing is chased beyond the risk pool).
    ///      This function carries **no delay of its own**: the delay is guaranteed by the controller before execution (see `src/SlashTimelock.sol`).
    function slashSolver(bytes32 solverId, uint256 amount, bytes32 reason) external nonReentrant {
        if (msg.sender != slashController) revert Errors.NotSlashController();
        if (address(solverRegistry) == address(0)) revert Errors.NotRegistered();
        solverRegistry.slash(solverId, amount, reason);
        emit SolverSlashed(solverId, amount, reason);
    }

    // ------------------------------------------------------------ Digest

    /// @notice Settlement digest: binds the chain ID, the settlement contract address, and the **specific fills**, preventing cross-chain replay and "allocation swaps".
    /// @dev `06` §6 requires the digest to bind chain and contract; on 2026-09-25, `keccak256(abi.encode(fills))` was added:
    ///      before that, the same receipt could be swapped for a different allocation within the "maximum-remainder solution set" (differing by ≤1 smallest unit per order),
    ///      so verifiers were not signing "this exact allocation". See docs/17 M-2 and docs/05 §27.
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

    /// @notice The epoch in which this digest was consumed (0 if never consumed). Used for cross-epoch anchoring checks (RT-4).
    function epochOfDigest(bytes32 digest) external view returns (uint64) {
        return _digestEpoch[digest];
    }

    function epochSettled(uint64 epoch) external view returns (bool) {
        return _epochSettled[epoch];
    }

    // ------------------------------------------------------------ Settlement

    /// @notice Settle one batch. Anyone may submit, as long as the receipt is valid and recomputation matches.
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
        // The settlement window declared in the payload must not exceed the on-chain refund window (a shorter window may be chosen).
        // An empty payload (deadline=0) is let through here and left for the verifier to report a structural error (OrderSetMismatch), keeping error-code semantics intact.
        if (batch.deadline > orderBook.epochDeadlineBlock(batch.epoch)) revert Errors.InvalidOrder();

        // Match validity: binding checks -> recompute clearing price -> compare with payload -> volume bounds -> allocation checks
        // (including per-fill limit prices and two-sided conservation). These checks all need order contents, so they live in the per-tier verifier;
        // the settlement layer reads no order contents and only consumes the volume it recomputes (docs/09 §2 and §3.1).
        uint256 volume = matchVerifier.verifyMatch(batch, matchProof);

        // Settlement window (third-round supplementary review C: tier-independent). Placed after the verifier: structural/reveal errors are reported
        // first by each tier's verifier (OrderSetMismatch / RevealExpired), and only an out-of-window case reports EpochClosed — existing error-code wording unchanged.
        if (block.number > batch.deadline) revert Errors.EpochClosed();
        // Per-order validity (RT-16 semantics B, 2026-09-27): **expired orders do not take part in matching** — they stay in the closed set
        // (set binding and set hash unchanged), but any fill involving one is rejected. This rule lives in each tier's verifier because it needs
        // the alignment with fills (O(n+f)); looking up fills per order in the settlement layer would be O(n·f) and cost several M extra gas at 200 orders.
        //   Plaintext tier: `PlaintextMatchVerifier._verifyFills` (checks during alignment) + `_scan` skips expired orders;
        //   Sealed tier: `SealedMatchVerifier._verifyAllocation` (checks during alignment).
        // New tiers must answer the same question (interface comments unchanged).

        // Solver risk gate (audit M-2 and round-2 N-1/N-2):
        //   (1) Registry unbound -> **reject** (it used to be silently skipped, which made the gate vanish; local drills can open it with setRegistryRequired(false))
        //   (2) Registered + bond ≥ minBond
        //   (3) **Exposure lower-bound constraint**: a single batch's notional must not exceed the per-order cap, must not exceed available bond, and must not push total exposure past the cap once counted
        // Full exposure-window bookkeeping (open/closeExposure) still belongs to the "dispatch" step (confirmed in D-4),
        // but the lower-bound constraint here guarantees "bond covers at least the single-batch notional", so it is no longer just an entry ticket.
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
            // `notionalQuote` and the registry's bond/exposure must all be in the same asset unit; without
            // a reviewed price oracle, cross-asset comparison would produce a risk cap with no economic meaning.
            if (batch.quoteToken != address(solverRegistry.bondToken())) revert Errors.SolverBondTokenMismatch();
            // M-2/M-3 (docs/20): settlement must come from the **solver dispatched for this batch**
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
            // RT-2 (red-team freeze-1): this batch already called `openExposure(hold)` at `dispatch`, and the hold is counted in total exposure;
            // checking "exposure + this batch's notional" again here would count this batch's reservation twice — under a valid configuration
            // with `singleOrderBps == totalExposureBps`, settlement would never succeed, and under factory parameters the 10th concurrent batch could not settle either.
            // Correct approach: exclude this batch's own reservation from used exposure, then check "other exposure + this batch's notional ≤ total cap".
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

        // Settlement succeeded: close the exposure locked at dispatch (if a registry is bound)
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

    /// @notice Refund entry point. Shares the same OrderBook logic and state guards as user self-service refunds; the two paths are mutually exclusive.
    function refund(bytes32 orderId) external nonReentrant {
        orderBook.refundOnSettlement(orderId, msg.sender);
        emit Refunded(orderId);
    }

    // ------------------------------------------------------------ Internal

    /// @dev Posting (docs/09 §3.3, step 8): map the fills into an array in close order and hand them to OrderBook in one bulk call.
    ///      The per-fill limit-price checks and two-sided conservation that used to live here **need order contents** (direction + limit price) and have moved
    ///      into `PlaintextMatchVerifier` along with `_verifyAllocation`; `volume` is
    ///      recomputed and returned by `matchVerifier.verifyMatch` (the interface keeps that return value per §3.1). This function only posts,
    ///      so the settlement layer never needs to read order contents — which is also the mechanical prerequisite for acceptance criterion 3.
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
            if (batch.fills[f].orderId != batch.orderIds[i]) continue; // Unfilled order
            filledIds[f] = batch.fills[f].orderId;
            filledSolds[f] = batch.fills[f].amountSold;
            f++;
        }
        if (f != batch.fills.length) revert Errors.RecomputeMismatch();

        orderBook.settleBatch(filledIds, filledSolds, batch.solver);
    }
}
