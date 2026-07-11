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
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";
import {BPS, WAD} from "contracts/libraries/ConstantsLib.sol";

/// @title Small-state incentive economic-gap investigation (T-05)
contract TestIncentiveEconomicGap is TestBaseLendingOptimizer {
    struct MarketState {
        address market;
        uint256 allocation;
        uint256 cash;
        uint256 debt;
        uint256 fees;
        uint256 capWad;
        IDynamicIRM irm;
    }

    struct GapResult {
        uint256 plannerObjective;
        uint256 sampledBestObjective;
        uint256 gapBps;
        int256 plannerDeltaToMarketOne;
        int256 sampledBestDeltaToMarketOne;
    }

    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    OptimizerReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), 0
        );
        _setUpTwoMarketOptimizer();
    }

    function test_report_smallStateOptimalityGap() public {
        uint256[2][6] memory incentiveCases = [
            [uint256(0), uint256(0)],
            [uint256(0), uint256(100)],
            [uint256(100), uint256(0)],
            [uint256(0), uint256(1_000)],
            [uint256(1_000), uint256(0)],
            [uint256(300), uint256(700)]
        ];
        uint256[3] memory chunkCases = [uint256(10), 20, 50];
        uint256 maxGapBps;
        uint256 maxGapCase;
        uint256 maxGapChunks;
        int256 maxGapPlannerDelta;
        int256 maxGapSampledBestDelta;

        for (uint256 i; i < incentiveCases.length; ++i) {
            for (uint256 j; j < chunkCases.length; ++j) {
                GapResult memory result =
                    _measureGap(incentiveCases[i], chunkCases[j]);
                assertGe(
                    result.sampledBestObjective,
                    result.plannerObjective,
                    "sampled best must include planner candidate"
                );
                if (result.gapBps > maxGapBps) {
                    maxGapBps = result.gapBps;
                    maxGapCase = i;
                    maxGapChunks = chunkCases[j];
                    maxGapPlannerDelta = result.plannerDeltaToMarketOne;
                    maxGapSampledBestDelta = result.sampledBestDeltaToMarketOne;
                }
            }
        }

        emit log_named_uint("maximum sampled economic gap BPS", maxGapBps);
        emit log_named_uint(
            "max-gap market-zero incentive BPS", incentiveCases[maxGapCase][0]
        );
        emit log_named_uint(
            "max-gap market-one incentive BPS", incentiveCases[maxGapCase][1]
        );
        emit log_named_uint("max-gap chunks", maxGapChunks);
        emit log_named_int("planner delta to market one", maxGapPlannerDelta);
        emit log_named_int(
            "sampled-best delta to market one", maxGapSampledBestDelta
        );
    }

    function testFuzz_sampledEconomicGapIsWellFormed(
        uint16 rawIncentiveZero,
        uint16 rawIncentiveOne,
        uint8 rawChunks
    ) public {
        uint256[2] memory incentiveBps = [
            uint256(rawIncentiveZero) % 1_001, uint256(rawIncentiveOne) % 1_001
        ];
        uint256 chunks = uint256(rawChunks) % 49 + 2;
        GapResult memory result = _measureGap(incentiveBps, chunks);

        assertGe(
            result.sampledBestObjective,
            result.plannerObjective,
            "sampled best below planner"
        );
        assertLe(result.gapBps, BPS, "gap exceeds 100 percent");
    }

    function _measureGap(uint256[2] memory incentiveBps, uint256 chunks)
        internal
        returns (GapResult memory result)
    {
        int256 plannerDelta;
        {
            (
                LendingOptimizer.ReallocationAction[] memory actions,
                LendingOptimizer.AllocationBound[] memory bounds
            ) = reader.optimalRebalanceWithIncentives(
                address(optimizer), 500, chunks, _incentives(incentiveBps)
            );
            if (actions.length > 0) {
                assertEq(actions.length, 2, "planner action shape");
                assertEq(bounds.length, 2, "planner bounds shape");
                assertEq(
                    actions[0].assetsOrBps + actions[1].assetsOrBps,
                    0,
                    "planner actions unbalanced"
                );
                plannerDelta = actions[1].assetsOrBps;
            }
        }

        MarketState[2] memory markets = _snapshotMarkets();
        uint256 totalAssets = markets[0].allocation + markets[1].allocation;
        (uint256 plannerAllocationZero, uint256 plannerAllocationOne) =
            _allocationsAfterDelta(markets, plannerDelta);
        result.plannerObjective = _objective(
            markets, incentiveBps, plannerAllocationZero, plannerAllocationOne
        );
        result.sampledBestObjective = result.plannerObjective;
        result.plannerDeltaToMarketOne = plannerDelta;
        result.sampledBestDeltaToMarketOne = plannerDelta;

        (result.sampledBestObjective, result.sampledBestDeltaToMarketOne) =
            _sampleBest(
                markets,
                incentiveBps,
                chunks,
                totalAssets,
                result.sampledBestObjective,
                result.sampledBestDeltaToMarketOne
            );

        if (result.sampledBestObjective > 0) {
            result.gapBps = FixedPointMathLib.fullMulDiv(
                result.sampledBestObjective - result.plannerObjective,
                BPS,
                result.sampledBestObjective
            );
        }
    }

    function _sampleBest(
        MarketState[2] memory markets,
        uint256[2] memory incentiveBps,
        uint256 chunks,
        uint256 totalAssets,
        uint256 initialBestObjective,
        int256 initialBestDelta
    ) internal view returns (uint256 bestObjective, int256 bestDelta) {
        bestObjective = initialBestObjective;
        bestDelta = initialBestDelta;
        uint256 chunkSize = totalAssets / chunks;
        if (chunkSize == 0) chunkSize = 1;
        for (int256 step = -int256(chunks); step <= int256(chunks); ++step) {
            int256 delta = step * int256(chunkSize);
            if (!_isFeasible(markets, totalAssets, delta)) continue;

            (uint256 allocationZero, uint256 allocationOne) =
                _allocationsAfterDelta(markets, delta);
            uint256 candidateObjective = _objective(
                markets, incentiveBps, allocationZero, allocationOne
            );
            if (candidateObjective > bestObjective) {
                bestObjective = candidateObjective;
                bestDelta = delta;
            }
        }
    }

    function _objective(
        MarketState[2] memory markets,
        uint256[2] memory incentiveBps,
        uint256 allocationZero,
        uint256 allocationOne
    ) internal view returns (uint256) {
        int256 delta = int256(allocationOne) - int256(markets[1].allocation);
        uint256 cashZero = delta >= 0
            ? markets[0].cash - uint256(delta)
            : markets[0].cash + uint256(-delta);
        uint256 cashOne = delta >= 0
            ? markets[1].cash + uint256(delta)
            : markets[1].cash - uint256(-delta);

        uint256 scoreZero = _score(markets[0], cashZero, incentiveBps[0]);
        uint256 scoreOne = _score(markets[1], cashOne, incentiveBps[1]);
        return FixedPointMathLib.fullMulDiv(allocationZero, scoreZero, WAD)
            + FixedPointMathLib.fullMulDiv(allocationOne, scoreOne, WAD);
    }

    function _score(
        MarketState memory market,
        uint256 cash,
        uint256 incentiveBps
    ) internal view returns (uint256) {
        uint256 rate = market.irm.supplyRate(cash, market.debt, market.fees);
        uint256 nativeAnnual = rate > type(uint256).max / SECONDS_PER_YEAR
            ? type(uint256).max
            : rate * SECONDS_PER_YEAR;
        uint256 incentiveAnnual = incentiveBps * WAD / BPS;
        return nativeAnnual > type(uint256).max - incentiveAnnual
            ? type(uint256).max
            : nativeAnnual + incentiveAnnual;
    }

    function _isFeasible(
        MarketState[2] memory markets,
        uint256 totalAssets,
        int256 delta
    ) internal pure returns (bool) {
        uint256 allocationZero;
        uint256 allocationOne;
        if (delta >= 0) {
            uint256 amount = uint256(delta);
            if (amount > markets[0].allocation || amount > markets[0].cash) {
                return false;
            }
            allocationZero = markets[0].allocation - amount;
            allocationOne = markets[1].allocation + amount;
        } else {
            uint256 amount = uint256(-delta);
            if (amount > markets[1].allocation || amount > markets[1].cash) {
                return false;
            }
            allocationZero = markets[0].allocation + amount;
            allocationOne = markets[1].allocation - amount;
        }

        return FixedPointMathLib.fullMulDiv(allocationZero, WAD, totalAssets)
                <= markets[0].capWad
            && FixedPointMathLib.fullMulDiv(allocationOne, WAD, totalAssets)
                <= markets[1].capWad;
    }

    function _allocationsAfterDelta(
        MarketState[2] memory markets,
        int256 delta
    ) internal pure returns (uint256 allocationZero, uint256 allocationOne) {
        if (delta >= 0) {
            allocationZero = markets[0].allocation - uint256(delta);
            allocationOne = markets[1].allocation + uint256(delta);
        } else {
            allocationZero = markets[0].allocation + uint256(-delta);
            allocationOne = markets[1].allocation - uint256(-delta);
        }
    }

    function _snapshotMarkets()
        internal
        view
        returns (MarketState[2] memory markets)
    {
        address[2] memory addresses = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET];
        for (uint256 i; i < 2; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(addresses[i]);
            markets[i] = MarketState({
                market: addresses[i],
                allocation: cToken.convertToAssets(
                    cToken.balanceOf(address(optimizer))
                ),
                cash: cToken.assetsHeld(),
                debt: cToken.marketOutstandingDebt(),
                fees: cToken.interestFee(),
                capWad: optimizer.allocationCaps(addresses[i]),
                irm: cToken.IRM()
            });
        }
    }

    function _setUpTwoMarketOptimizer() internal {
        address[] memory markets = new address[](2);
        markets[0] = cUSDC_WMON_MARKET;
        markets[1] = cUSDC_WBTC_MARKET;
        uint256[] memory caps = new uint256[](2);
        caps[0] = 6_000;
        caps[1] = 6_000;
        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, markets, caps, 0
        );

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(optimizer), 77777);
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);
        for (uint256 i; i < markets.length; ++i) {
            deal(USDC_MONAD, address(this), 200_000e6);
            IERC20(USDC_MONAD).approve(address(optimizer), 200_000e6);
            LendingOptimizerHarness(address(optimizer))
                .depositToMarket(200_000e6, address(this), markets[i]);
        }
    }

    function _incentives(uint256[2] memory incentiveBps)
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        incentives = new OptimizerReader.MarketIncentiveAPYBps[](2);
        incentives[0] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: cUSDC_WMON_MARKET, incentiveAPYBps: incentiveBps[0]
        });
        incentives[1] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: cUSDC_WBTC_MARKET, incentiveAPYBps: incentiveBps[1]
        });
    }
}
