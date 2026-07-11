// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IDynamicIRM} from "contracts/interfaces/IDynamicIRM.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";
import {BPS, WAD} from "contracts/libraries/ConstantsLib.sol";

contract IncentiveScoreReaderHarness is OptimizerReader {
    constructor(ICentralRegistry centralRegistry)
        OptimizerReader(centralRegistry, 0)
    {}

    function exposedScore(
        IDynamicIRM irm,
        uint256 assetsHeld,
        uint256 debt,
        uint256 fees,
        uint256 incentiveBps
    ) external view returns (uint256) {
        MarketAlloc memory market;
        market.irm = irm;
        market.debt = debt;
        market.fees = fees;
        market.incentiveAPY = FixedPointMathLib.mulDiv(incentiveBps, WAD, BPS);
        return _allocationScore(market, assetsHeld);
    }

    function exposedScoreWithRawIncentive(
        IDynamicIRM irm,
        uint256 assetsHeld,
        uint256 debt,
        uint256 fees,
        uint256 incentiveAPYWad
    ) external view returns (uint256) {
        MarketAlloc memory market;
        market.irm = irm;
        market.debt = debt;
        market.fees = fees;
        market.incentiveAPY = incentiveAPYWad;
        return _allocationScore(market, assetsHeld);
    }
}

contract FlatSupplyRateModel {
    uint256 internal immutable ratePerSecond;

    constructor(uint256 ratePerSecond_) {
        ratePerSecond = ratePerSecond_;
    }

    function supplyRate(uint256, uint256, uint256)
        external
        view
        returns (uint256)
    {
        return ratePerSecond;
    }
}

/// @title Exact incentive score crossover properties (T-04, P-12)
contract TestIncentiveScoreCrossover is TestBaseLendingOptimizer {
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant MAX_INCENTIVE_BPS = 1_000;
    uint256 internal constant DEPOSIT_PER_MARKET = 200_000e6;

    IncentiveScoreReaderHarness internal reader;

    function setUp() public override {
        super.setUp();
        reader = new IncentiveScoreReaderHarness(liveCentralRegistry);
    }

    function testFuzz_scoreUsesExactAnnualAndBpsUnits(
        uint128 rawRatePerSecond,
        uint16 rawIncentiveBps,
        uint128 assetsHeld,
        uint128 debt,
        uint16 fees
    ) public {
        uint256 maxRate =
            type(uint256).max / SECONDS_PER_YEAR;
        uint256 ratePerSecond = uint256(rawRatePerSecond) % (maxRate + 1);
        uint256 incentiveBps =
            uint256(rawIncentiveBps) % (MAX_INCENTIVE_BPS + 1);
        FlatSupplyRateModel irm = new FlatSupplyRateModel(ratePerSecond);

        uint256 actual = reader.exposedScore(
            IDynamicIRM(address(irm)), assetsHeld, debt, fees, incentiveBps
        );
        uint256 expected =
            ratePerSecond * SECONDS_PER_YEAR + incentiveBps * WAD / BPS;

        assertEq(actual, expected, "incorrect annual or BPS score units");
    }

    function test_rawScoreBoundary_isStrictBeforeEqualAndAfter() public {
        FlatSupplyRateModel irm = new FlatSupplyRateModel(123_456_789);
        uint256 sourceIncentive = 5e16;
        uint256 sourceScore = reader.exposedScoreWithRawIncentive(
            IDynamicIRM(address(irm)), 1, 2, 3, sourceIncentive
        );
        uint256 below = reader.exposedScoreWithRawIncentive(
            IDynamicIRM(address(irm)), 999, 888, 777, sourceIncentive - 1
        );
        uint256 equal = reader.exposedScoreWithRawIncentive(
            IDynamicIRM(address(irm)), 999, 888, 777, sourceIncentive
        );
        uint256 above = reader.exposedScoreWithRawIncentive(
            IDynamicIRM(address(irm)), 999, 888, 777, sourceIncentive + 1
        );

        assertLt(below, sourceScore, "one WAD unit below should lose");
        assertEq(equal, sourceScore, "equal score should tie exactly");
        assertGt(above, sourceScore, "one WAD unit above should win");
    }

    function test_equalScores_doNotMove() public {
        _setUpFlatTwoMarketOptimizer(2_000_000_000, 2_000_000_000);
        uint256[2] memory incentiveBps = [uint256(500), 500];

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            _plan(incentiveBps, 200);

        assertEq(actions.length, 0, "equal post-move scores must not move");
    }

    function test_equalScores_mintPausedSourceStillDoesNotMove() public {
        _setUpFlatTwoMarketOptimizer(2_000_000_000, 2_000_000_000);
        address manager =
            address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager());
        vm.mockCall(
            manager,
            abi.encodeWithSelector(
                IMarketManager.actionsPaused.selector, cUSDC_WMON_MARKET
            ),
            abi.encode(true, false, false)
        );
        uint256[2] memory incentiveBps = [uint256(500), 500];

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            _plan(incentiveBps, 200);

        assertEq(actions.length, 0, "equal scores must not drain a source");
    }

    function test_oneBpsAdvantage_movesTowardHigherScore() public {
        _setUpFlatTwoMarketOptimizer(2_000_000_000, 2_000_000_000);
        uint256[2] memory incentiveBps = [uint256(500), 501];

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            _plan(incentiveBps, 200);

        assertEq(actions.length, 2, "one-BPS advantage should produce a plan");
        assertLt(actions[0].assetsOrBps, 0, "lower score should be the source");
        assertGt(
            actions[1].assetsOrBps, 0, "higher score should be the destination"
        );
    }

    function testFuzz_oneBpsAdvantageDeterminesDirection(
        uint64 rawRatePerSecond,
        uint16 rawBaseIncentiveBps,
        uint16 rawChunks,
        bool higherIsMarketZero
    ) public {
        uint256 ratePerSecond = uint256(rawRatePerSecond);
        _setUpFlatTwoMarketOptimizer(ratePerSecond, ratePerSecond);
        uint256 baseBps = uint256(rawBaseIncentiveBps) % MAX_INCENTIVE_BPS;
        uint256[2] memory incentiveBps = higherIsMarketZero
            ? [baseBps + 1, baseBps]
            : [baseBps, baseBps + 1];
        uint256 chunks = uint256(rawChunks) % 500 + 1;

        (LendingOptimizer.ReallocationAction[] memory actions,) =
            _plan(incentiveBps, chunks);

        assertEq(actions.length, 2, "one-BPS advantage should produce a plan");
        uint256 winner = higherIsMarketZero ? 0 : 1;
        uint256 loser = 1 - winner;
        assertGt(
            actions[winner].assetsOrBps, 0, "winner should receive assets"
        );
        assertLt(actions[loser].assetsOrBps, 0, "loser should provide assets");
        assertEq(
            actions[winner].assetsOrBps,
            -actions[loser].assetsOrBps,
            "two-market movement must balance"
        );
    }

    function _setUpFlatTwoMarketOptimizer(
        uint256 marketZeroRate,
        uint256 marketOneRate
    ) internal {
        address[] memory markets = new address[](2);
        markets[0] = cUSDC_WMON_MARKET;
        markets[1] = cUSDC_WBTC_MARKET;
        uint256[] memory caps = new uint256[](2);
        caps[0] = BPS;
        caps[1] = BPS;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, markets, caps, 0
        );
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(optimizer), 77777);
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        _depositToMarket(cUSDC_WMON_MARKET, DEPOSIT_PER_MARKET);
        _depositToMarket(cUSDC_WBTC_MARKET, DEPOSIT_PER_MARKET);

        FlatSupplyRateModel marketZeroIrm =
            new FlatSupplyRateModel(marketZeroRate);
        FlatSupplyRateModel marketOneIrm =
            new FlatSupplyRateModel(marketOneRate);
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.IRM.selector),
            abi.encode(address(marketZeroIrm))
        );
        vm.mockCall(
            cUSDC_WBTC_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.IRM.selector),
            abi.encode(address(marketOneIrm))
        );
    }

    function _depositToMarket(address market, uint256 assets) internal {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(address(optimizer), assets);
        LendingOptimizerHarness(address(optimizer))
            .depositToMarket(assets, address(this), market);
    }

    function _plan(uint256[2] memory incentiveBps, uint256 chunks)
        internal
        returns (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        )
    {
        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            new OptimizerReader.MarketIncentiveAPYBps[](2);
        incentives[0] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: cUSDC_WMON_MARKET, incentiveAPYBps: incentiveBps[0]
        });
        incentives[1] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: cUSDC_WBTC_MARKET, incentiveAPYBps: incentiveBps[1]
        });

        return reader.optimalRebalanceWithIncentives(
            address(optimizer), 0, chunks, incentives
        );
    }
}
