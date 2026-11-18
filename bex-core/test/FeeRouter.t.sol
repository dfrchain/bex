// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { FeeRouter } from "../src/FeeRouter.sol";

/// @notice Fee layer v1 (step D of `docs/35`): frozen interface and split math, **money path closed**.
/// @dev This file turns each invariant of design note §6 into an assertion; of these, I1/I4/I5 (user amounts unchanged, refunds fee-free,
///      no effect on allocation invariants) hold **structurally** in v1 — `collect()` always reverts and has no call sites,
///      so they are represented here by "money path closed + no transfer path", with end-to-end cases to be added once fees are enabled.
contract FeeRouterTest is Test {
    address internal constant SOLVER = address(0x5017);
    address internal constant RISK_POOL = address(0x8157);
    address internal constant OPS = address(0x0055);
    uint256 internal constant CAP_BPS = 100; // 1% hard cap (docs/31 group B)

    function _v1Config() internal pure returns (FeeRouter.Config memory) {
        return FeeRouter.Config({
            feeBps: 0, // v1: fee switch off by default
            capBps: CAP_BPS,
            minFee: 50_000, // 0.05 USDT (6 decimals)
            solverBps: 8_000, // 80%
            riskPoolBps: 1_500, // 15%
            opsBps: 500, // 5%
            solver: SOLVER,
            riskPool: RISK_POOL,
            ops: OPS
        });
    }

    function _deploy(FeeRouter.Config memory config) internal returns (FeeRouter) {
        return new FeeRouter(config);
    }

    // ------------------------------------------------------------ v1 behavior

    function test_V1ConfigDeploysAndQuotesZero() public {
        FeeRouter router = _deploy(_v1Config());
        assertEq(router.FEE_BPS(), 0, "v1 fee must be zero");
        assertEq(router.CAP_BPS(), CAP_BPS);

        FeeRouter.Split memory s = router.quote(1_000e6);
        assertEq(s.total, 0, "fee=0 -> total 0");
        assertEq(s.toSolver, 0);
        assertEq(s.toRiskPool, 0);
        assertEq(s.toOps, 0);

        FeeRouter.Config memory c = router.config();
        assertEq(c.solverBps + c.riskPoolBps + c.opsBps, 10_000, "split must be 100%");
        assertEq(c.solver, SOLVER);
        assertEq(c.minFee, 50_000);
    }

    /// Money path closed: `collect()` must explicitly reject, not return 0 and let callers think "fee collected".
    function test_V1CollectIsDisabled() public {
        FeeRouter router = _deploy(_v1Config());
        vm.expectRevert(FeeRouter.FeeCollectionDisabled.selector);
        router.collect(1, bytes32(uint256(0xabc)), 1_000e6, SOLVER);
    }

    // ------------------------------------------------------------ Deploy-time bounds (I6 + parameter table)

    function test_RejectsFeeAboveCapOrNonZeroInV1() public {
        FeeRouter.Config memory c = _v1Config();
        c.feeBps = 1; // v1 must be 0
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "feeBps!=0"));
        _deploy(c);
    }

    function test_RejectsCapOutOfBounds() public {
        FeeRouter.Config memory c = _v1Config();
        c.capBps = 101;
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "capBps"));
        _deploy(c);

        c = _v1Config();
        c.capBps = 0;
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "capBps"));
        _deploy(c);
    }

    function test_RejectsMinFeeAboveOneUsdt() public {
        FeeRouter.Config memory c = _v1Config();
        c.minFee = 1_000_001; // > 1 USDT (6 decimals)
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "minFee"));
        _deploy(c);
    }

    function test_RejectsSolverShareOutOfBounds() public {
        FeeRouter.Config memory c = _v1Config();
        c.solverBps = 4_999;
        c.riskPoolBps = 4_001;
        c.opsBps = 1_000;
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "solverBps"));
        _deploy(c);

        c = _v1Config();
        c.solverBps = 9_001;
        c.riskPoolBps = 499;
        c.opsBps = 500;
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "solverBps"));
        _deploy(c);
    }

    function test_RejectsTripShareNotHundred() public {
        FeeRouter.Config memory c = _v1Config();
        c.opsBps = 400; // 8000 + 1500 + 400 = 9900
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "split!=100%"));
        _deploy(c);
    }

    function test_RejectsRecipientsZeroOrDuplicated() public {
        FeeRouter.Config memory c = _v1Config();
        c.ops = address(0);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "recipient"));
        _deploy(c);

        c = _v1Config();
        c.ops = RISK_POOL; // Duplicates the risk pool
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "recipient"));
        _deploy(c);
    }

    // ------------------------------------------------------------ Split math (I2/I3/I8)

    /// Aligned with `spec/09` decision 3: a 1,000 USDT order at 5 bp -> fee 0.5, solver 0.4, risk pool 0.075, ops 0.025
    function test_QuoteMatchesSpecEconomics() public {
        FeeRouter router = _deploy(_v1Config());
        FeeRouter.Split memory s = router.quoteAt(1_000e6, 5);
        assertEq(s.total, 500_000, "0.5 USDT");
        assertEq(s.toSolver, 400_000, "0.4 USDT = 80%");
        assertEq(s.toRiskPool, 75_000, "0.075 USDT = 15%");
        assertEq(s.toOps, 25_000, "0.025 USDT = 5%");
    }

    /// Rounding direction: fees round up (even a fraction of one smallest unit is charged as 1), remainder goes to the solver
    function test_RoundingIsUpForFeeAndRemainderToSolver() public {
        // Zero minFee on its own to isolate the "rounding" rule (otherwise the minimum fee would push the result to 0.05 USDT)
        FeeRouter.Config memory c = _v1Config();
        c.minFee = 0;
        FeeRouter router = _deploy(c);
        FeeRouter.Split memory s = router.quoteAt(1, 5); // 1 smallest unit x 5bp
        assertEq(s.total, 1, "fee rounds up");
        assertEq(s.toRiskPool, 0);
        assertEq(s.toOps, 0);
        assertEq(s.toSolver, 1, "remainder to solver");
    }

    /// Minimum fee does not apply when fees are off (otherwise "rate off" would read as a forced 0.05 USDT charge)
    function test_MinFeeDoesNotApplyWhenRateIsZero() public {
        FeeRouter router = _deploy(_v1Config()); // minFee = 0.05 USDT, feeBps = 0
        assertEq(router.quoteAt(1_000e6, 0).total, 0, "zero rate -> zero fee");
    }

    /// Minimum fee: when the bps part falls short of `minFee`, top it up, with the **shortfall going entirely to the solver** (the protocol takes nothing, spec/09 decision 2)
    function test_MinFeeTopsUpAndGoesToSolver() public {
        FeeRouter router = _deploy(_v1Config());
        FeeRouter.Split memory s = router.quoteAt(1e6, 5); // 1 USDT × 5bp = 0.0005 USDT < 0.05
        assertEq(s.total, 50_000, "topped up to minFee");
        assertEq(s.toRiskPool, 75, "risk pool only on the bps part");
        assertEq(s.toOps, 25);
        assertEq(s.toSolver, 50_000 - 100, "the minFee gap goes to the solver");
    }

    /// I2: split identity; I3: total fee = max(ceil(notional x feeBps/1e4), minFee)
    function test_SplitConservationAndFormula() public {
        FeeRouter router = _deploy(_v1Config());
        uint256[6] memory notionals = [uint256(1), 999, 1e6, 123_456_789, 1_000e6, 999_999e6];
        uint256[5] memory rates = [uint256(0), 1, 5, 30, 100];
        for (uint256 i = 0; i < notionals.length; i++) {
            for (uint256 j = 0; j < rates.length; j++) {
                FeeRouter.Split memory s = router.quoteAt(notionals[i], rates[j]);
                assertEq(s.total, s.toSolver + s.toRiskPool + s.toOps, "I2: split must sum to total");
                uint256 expected = 0;
                if (rates[j] != 0) {
                    uint256 bps = notionals[i] * rates[j];
                    expected = bps == 0 ? 0 : ((bps - 1) / 10_000) + 1;
                    if (expected < router.MIN_FEE()) expected = router.MIN_FEE();
                }
                assertEq(s.total, expected, "I3: rate=0 -> 0; else max(ceil(notional*bps/1e4), minFee)");
            }
        }
    }

    /// Fee rate must not exceed the hard cap (guards against governance runaway, I3)
    function test_QuoteAtRejectsRateAboveCap() public {
        FeeRouter router = _deploy(_v1Config());
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "feeBps"));
        router.quoteAt(1_000e6, CAP_BPS + 1);
    }
}
