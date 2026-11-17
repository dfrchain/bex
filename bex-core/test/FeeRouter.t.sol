// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { FeeRouter } from "../src/FeeRouter.sol";

/// @notice 费用层 v1（`docs/35` 的 D 步）：接口与分账数学冻结、**钱路关闭**。
/// @dev 本文件把设计单 §六 的不变量逐条落成断言；其中 I1/I4/I5（用户金额不变、退款不受费、
///      不影响分配不变量）在 v1 是**结构性成立**的——`collect()` 一律 revert 且没有任何调用点，
///      因此这里用"钱路关闭 + 没有转账路径"来代表，等开收费时再补端到端用例。
contract FeeRouterTest is Test {
    address internal constant SOLVER = address(0x5017);
    address internal constant RISK_POOL = address(0x8157);
    address internal constant OPS = address(0x0055);
    uint256 internal constant CAP_BPS = 100; // 1% 硬上限（docs/31 B 组）

    function _v1Config() internal pure returns (FeeRouter.Config memory) {
        return FeeRouter.Config({
            feeBps: 0, // v1：收费开关默认关
            capBps: CAP_BPS,
            minFee: 50_000, // 0.05 USDT（6 位小数）
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

    // ------------------------------------------------------------ v1 行为

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

    /// 钱路关闭：`collect()` 必须显式拒绝，不能返回 0 让调用方误以为"已收费"
    function test_V1CollectIsDisabled() public {
        FeeRouter router = _deploy(_v1Config());
        vm.expectRevert(FeeRouter.FeeCollectionDisabled.selector);
        router.collect(1, bytes32(uint256(0xabc)), 1_000e6, SOLVER);
    }

    // ------------------------------------------------------------ 部署期上下界（I6 + 参数表）

    function test_RejectsFeeAboveCapOrNonZeroInV1() public {
        FeeRouter.Config memory c = _v1Config();
        c.feeBps = 1; // v1 必须为 0
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
        c.minFee = 1_000_001; // > 1 USDT（6 位小数）
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
        c.ops = RISK_POOL; // 与风险池重复
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "recipient"));
        _deploy(c);
    }

    // ------------------------------------------------------------ 分账数学（I2/I3/I8）

    /// 与 `spec/09` 决策三的口径对齐：1,000 USDT 单、5 bp → 费 0.5，求解者 0.4、风险池 0.075、运营 0.025
    function test_QuoteMatchesSpecEconomics() public {
        FeeRouter router = _deploy(_v1Config());
        FeeRouter.Split memory s = router.quoteAt(1_000e6, 5);
        assertEq(s.total, 500_000, "0.5 USDT");
        assertEq(s.toSolver, 400_000, "0.4 USDT = 80%");
        assertEq(s.toRiskPool, 75_000, "0.075 USDT = 15%");
        assertEq(s.toOps, 25_000, "0.025 USDT = 5%");
    }

    /// 取整方向：费用向上取整（不足 1 个最小单位也要收 1），余数归求解者
    function test_RoundingIsUpForFeeAndRemainderToSolver() public {
        // 单独把 minFee 归零，隔离"取整"这一条（否则最低收费会把结果顶到 0.05 USDT）
        FeeRouter.Config memory c = _v1Config();
        c.minFee = 0;
        FeeRouter router = _deploy(c);
        FeeRouter.Split memory s = router.quoteAt(1, 5); // 1 个最小单位 × 5bp
        assertEq(s.total, 1, "fee rounds up");
        assertEq(s.toRiskPool, 0);
        assertEq(s.toOps, 0);
        assertEq(s.toSolver, 1, "remainder to solver");
    }

    /// 费用关闭时最低收费不生效（否则"关费率"会被解读成强制收 0.05 USDT）
    function test_MinFeeDoesNotApplyWhenRateIsZero() public {
        FeeRouter router = _deploy(_v1Config()); // minFee = 0.05 USDT，feeBps = 0
        assertEq(router.quoteAt(1_000e6, 0).total, 0, "zero rate -> zero fee");
    }

    /// 最低收费：bps 部分不足 `minFee` 时补足，**差额全额归求解者**（协议不抽，spec/09 决策二）
    function test_MinFeeTopsUpAndGoesToSolver() public {
        FeeRouter router = _deploy(_v1Config());
        FeeRouter.Split memory s = router.quoteAt(1e6, 5); // 1 USDT × 5bp = 0.0005 USDT < 0.05
        assertEq(s.total, 50_000, "topped up to minFee");
        assertEq(s.toRiskPool, 75, "risk pool only on the bps part");
        assertEq(s.toOps, 25);
        assertEq(s.toSolver, 50_000 - 100, "the minFee gap goes to the solver");
    }

    /// I2：分账恒等；I3：总费 = max(ceil(notional×feeBps/1e4), minFee)
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

    /// 费率不得超过硬上限（防治理失控，I3）
    function test_QuoteAtRejectsRateAboveCap() public {
        FeeRouter router = _deploy(_v1Config());
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.FeeConfigOutOfBounds.selector, "feeBps"));
        router.quoteAt(1_000e6, CAP_BPS + 1);
    }
}
