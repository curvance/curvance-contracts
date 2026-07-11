// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {BPS, WAD} from "contracts/libraries/ConstantsLib.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";

contract TestOptimalRebalanceIncentivesScenarioFuzz is
    TestBaseLendingOptimizer
{
    struct Scenario {
        uint256[3] allocations;
        uint256[3] capsBps;
        uint256[3] incentivesBps;
        uint256 slippageBps;
        uint256 rebalanceChunks;
    }

    OptimizerReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), 0
        );
    }

    /// @notice Regression from bounded scenario fuzzing: the reader's
    ///         previewed post-action allocation is below the 43.60% cap, but
    ///         actual cToken withdrawal rounding leaves one extra base unit in
    ///         the cap-repair source and immediate execution reverts.
    function test_regression_incentivePlan_capRepairExecutesAfterRounding()
        public
    {
        uint256[3] memory capsBps = [uint256(4_049), 4_401, 4_360];
        uint256[3] memory allocations =
            [uint256(286_797_545_163), 148_032_871_614, 433_926_895_429];
        uint256[3] memory incentivesBps = [uint256(464), 481, 619];

        _setUpOptimizer(capsBps);
        _depositAllocations(allocations);

        address[3] memory markets = _markets();
        _seedAndBorrow(markets[0], 1e6, 49_491_067_597);
        _externalDeposit(markets[1], 888_559_599_028, 1);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceWithIncentives(
            address(optimizer),
            999,
            44,
            _incentivesInReverseOrder(incentivesBps)
        );

        uint256[] memory currentAssets = _marketAssets();
        uint256[] memory projectedAssets =
            _assertPreviewedPostStateWithinCaps(actions, currentAssets);

        optimizer.rebalance(actions, bounds);
        _assertActualPostState(bounds, projectedAssets);
    }

    /// @notice Fuzzes valid incentive plans across allocations, caps, market
    ///         liquidity/debt shocks, slippage, and chunk counts, then executes
    ///         every nonempty plan against unchanged state.
    function testFuzz_incentivePlan_boundedScenarioExecutes(
        uint256 allocationSeed,
        uint256 marketStateSeed,
        uint256 incentiveSeed,
        uint256 plannerSeed
    ) public {
        Scenario memory scenario = _buildScenario(
            allocationSeed, incentiveSeed, plannerSeed
        );

        _setUpOptimizer(scenario.capsBps);
        _depositAllocations(scenario.allocations);
        _applyMarketShocks(marketStateSeed);

        OptimizerReader.MarketIncentiveAPYBps[] memory incentives =
            _incentivesInReverseOrder(scenario.incentivesBps);

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceWithIncentives(
            address(optimizer),
            scenario.slippageBps,
            scenario.rebalanceChunks,
            incentives
        );

        _assertReturnShape(actions, bounds);
        if (actions.length == 0) return;

        uint256[] memory currentAssets = _marketAssets();
        uint256[] memory projectedAssets =
            _assertPreviewedPostStateWithinCaps(actions, currentAssets);

        _assertPlanShapeAndBounds(
            actions,
            bounds,
            projectedAssets,
            _sum(projectedAssets),
            scenario.slippageBps
        );
        _assertActionsConserveAndAreExecutable(actions, currentAssets);

        optimizer.rebalance(actions, bounds);

        _assertActualPostState(bounds, projectedAssets);
    }

    function _buildScenario(
        uint256 allocationSeed,
        uint256 incentiveSeed,
        uint256 plannerSeed
    ) internal pure returns (Scenario memory scenario) {
        for (uint256 i; i < 3; ++i) {
            scenario.allocations[i] = _draw(
                allocationSeed,
                keccak256(abi.encode("allocation", i)),
                1_000e6,
                500_000e6
            );
            scenario.capsBps[i] = _draw(
                allocationSeed, keccak256(abi.encode("cap", i)), 3_400, 10_000
            );
            scenario.incentivesBps[i] = _draw(
                incentiveSeed, keccak256(abi.encode("incentive", i)), 0, 1_000
            );
        }

        scenario.slippageBps =
            _draw(plannerSeed, keccak256("slippage"), 0, 1_000);
        scenario.rebalanceChunks =
            _draw(plannerSeed, keccak256("chunks"), 1, 500);
    }

    function _setUpOptimizer(uint256[3] memory capsBps) internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            allocationCapsBps[i] = capsBps[i];
        }

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
    }

    function _depositAllocations(uint256[3] memory allocations) internal {
        address[3] memory markets = _markets();
        uint256 total = allocations[0] + allocations[1] + allocations[2];

        deal(USDC_MONAD, address(this), total);
        IERC20(USDC_MONAD).approve(address(optimizer), total);

        for (uint256 i; i < 3; ++i) {
            LendingOptimizerHarness(address(optimizer))
                .depositToMarket(allocations[i], address(this), markets[i]);
        }
    }

    function _applyMarketShocks(uint256 marketStateSeed) internal {
        address[3] memory markets = _markets();

        for (uint256 i; i < 3; ++i) {
            uint256 mode =
                _draw(marketStateSeed, keccak256(abi.encode("mode", i)), 0, 2);

            if (mode == 1) {
                uint256 externalLiquidity = _draw(
                    marketStateSeed,
                    keccak256(abi.encode("liquidity", i)),
                    1_000e6,
                    2_000_000e6
                );
                _externalDeposit(markets[i], externalLiquidity, i);
            } else if (mode == 2) {
                uint256 additionalDebt = _draw(
                    marketStateSeed,
                    keccak256(abi.encode("debt", i)),
                    10_000e6,
                    100_000e6
                );
                _seedAndBorrow(markets[i], 1e6, additionalDebt);
            }
        }
    }

    function _externalDeposit(
        address market,
        uint256 assets,
        uint256 marketIndex
    ) internal {
        address lender = address(uint160(0xA000 + marketIndex));
        deal(USDC_MONAD, lender, assets);

        vm.startPrank(lender);
        IERC20(USDC_MONAD).approve(market, assets);
        IBorrowableCToken(market).deposit(assets, lender);
        vm.stopPrank();
    }

    function _incentivesInReverseOrder(uint256[3] memory incentivesBps)
        internal
        view
        returns (OptimizerReader.MarketIncentiveAPYBps[] memory incentives)
    {
        address[3] memory markets = _markets();
        incentives = new OptimizerReader.MarketIncentiveAPYBps[](3);

        for (uint256 i; i < 3; ++i) {
            uint256 marketIndex = 2 - i;
            incentives[i] = OptimizerReader.MarketIncentiveAPYBps({
                cToken: markets[marketIndex],
                incentiveAPYBps: incentivesBps[marketIndex]
            });
        }
    }

    function _assertReturnShape(
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) internal pure {
        assertEq(actions.length, bounds.length, "actions/bounds length");
        assertTrue(
            actions.length == 0 || actions.length == 3,
            "return length must be zero or market count"
        );
    }

    function _assertPlanShapeAndBounds(
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds,
        uint256[] memory projectedAssets,
        uint256 projectedTotal,
        uint256 slippageBps
    ) internal view {
        address[3] memory markets = _markets();

        for (uint256 i; i < 3; ++i) {
            assertEq(address(actions[i].cToken), markets[i], "action order");
            assertEq(bounds[i].cToken, markets[i], "bound order");

            uint256 projectedBpsDown = FixedPointMathLib.fullMulDiv(
                projectedAssets[i], BPS, projectedTotal
            );
            uint256 projectedBpsUp = FixedPointMathLib.fullMulDivUp(
                projectedAssets[i], BPS, projectedTotal
            );
            uint256 expectedMin = projectedBpsDown > slippageBps
                ? projectedBpsDown - slippageBps
                : 0;
            uint256 expectedMax = projectedBpsUp;
            if (expectedMax < BPS) {
                uint256 maxRoom = BPS - expectedMax;
                expectedMax += slippageBps < maxRoom ? slippageBps : maxRoom;
            }

            assertEq(bounds[i].minBps, expectedMin, "bound min");
            assertEq(bounds[i].maxBps, expectedMax, "bound max");
        }
    }

    function _assertActionsConserveAndAreExecutable(
        LendingOptimizer.ReallocationAction[] memory actions,
        uint256[] memory currentAssets
    ) internal view {
        uint256 deposits;
        uint256 withdrawals;

        for (uint256 i; i < actions.length; ++i) {
            int256 delta = actions[i].assetsOrBps;
            if (delta == 0) continue;

            IBorrowableCToken cToken = actions[i].cToken;
            uint256 amount = delta > 0 ? uint256(delta) : uint256(-delta);
            assertGt(cToken.convertToShares(amount), 0, "dust action");

            if (delta > 0) {
                deposits += amount;
            } else {
                withdrawals += amount;
                assertLe(amount, currentAssets[i], "withdraw exceeds position");
                assertLe(amount, cToken.assetsHeld(), "withdraw exceeds cash");
            }
        }

        assertEq(deposits, withdrawals, "actions must conserve assets");
    }

    function _assertPreviewedPostStateWithinCaps(
        LendingOptimizer.ReallocationAction[] memory actions,
        uint256[] memory currentAssets
    ) internal view returns (uint256[] memory postAssets) {
        postAssets = new uint256[](3);
        uint256 postTotal;

        for (uint256 i; i < 3; ++i) {
            postAssets[i] = _previewPostActionAssets(
                actions[i].cToken, currentAssets[i], actions[i].assetsOrBps
            );
            postTotal += postAssets[i];
        }

        for (uint256 i; i < 3; ++i) {
            uint256 allocationWad =
                FixedPointMathLib.fullMulDiv(postAssets[i], WAD, postTotal);
            assertLe(
                allocationWad,
                optimizer.allocationCaps(address(actions[i].cToken)),
                "previewed allocation exceeds cap"
            );
        }
    }

    function _assertActualPostState(
        LendingOptimizer.AllocationBound[] memory bounds,
        uint256[] memory projectedAssets
    ) internal view {
        uint256[] memory actualAssets = _marketAssets();
        uint256 actualTotal = _sum(actualAssets);

        assertEq(
            optimizer.totalAssets(),
            actualTotal,
            "optimizer accounting must match markets"
        );

        for (uint256 i; i < 3; ++i) {
            assertEq(
                actualAssets[i],
                projectedAssets[i],
                "projected assets must match execution"
            );

            uint256 allocationWad = FixedPointMathLib.fullMulDiv(
                actualAssets[i], WAD, actualTotal
            );
            assertLe(
                allocationWad,
                optimizer.allocationCaps(bounds[i].cToken),
                "actual allocation exceeds cap"
            );

            uint256 allocationBpsDown = FixedPointMathLib.fullMulDiv(
                actualAssets[i], BPS, actualTotal
            );
            uint256 allocationBpsUp = FixedPointMathLib.fullMulDivUp(
                actualAssets[i], BPS, actualTotal
            );
            assertGe(
                allocationBpsDown,
                bounds[i].minBps,
                "actual allocation below bound"
            );
            assertLe(
                allocationBpsUp,
                bounds[i].maxBps,
                "actual allocation above bound"
            );
        }
    }

    function _previewPostActionAssets(
        IBorrowableCToken cToken,
        uint256 currentAssets,
        int256 delta
    ) internal view returns (uint256) {
        uint256 currentShares = cToken.balanceOf(address(optimizer));

        if (delta > 0) {
            uint256 assetsToDeposit = uint256(delta);
            uint256 sharesToMint = cToken.previewDeposit(assetsToDeposit);
            return FixedPointMathLib.fullMulDiv(
                currentShares + sharesToMint,
                cToken.totalAssets() + assetsToDeposit,
                cToken.totalSupply() + sharesToMint
            );
        }

        if (delta < 0) {
            uint256 assetsToWithdraw = uint256(-delta);
            uint256 sharesToBurn = cToken.previewWithdraw(assetsToWithdraw);
            if (sharesToBurn >= currentShares) return 0;

            return FixedPointMathLib.fullMulDiv(
                currentShares - sharesToBurn,
                cToken.totalAssets() - assetsToWithdraw,
                cToken.totalSupply() - sharesToBurn
            );
        }

        return currentAssets;
    }

    function _marketAssets() internal view returns (uint256[] memory assets) {
        address[3] memory markets = _markets();
        assets = new uint256[](3);

        for (uint256 i; i < 3; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(markets[i]);
            assets[i] =
                cToken.convertToAssets(cToken.balanceOf(address(optimizer)));
        }
    }

    function _markets() internal view returns (address[3] memory markets) {
        markets[0] = cUSDC_WMON_MARKET;
        markets[1] = cUSDC_WBTC_MARKET;
        markets[2] = cUSDC_WETH_MARKET;
    }

    function _sum(uint256[] memory values)
        internal
        pure
        returns (uint256 result)
    {
        for (uint256 i; i < values.length; ++i) {
            result += values[i];
        }
    }

    function _draw(
        uint256 seed,
        bytes32 salt,
        uint256 minValue,
        uint256 maxValue
    ) internal pure returns (uint256) {
        return minValue + uint256(keccak256(abi.encode(seed, salt)))
            % (maxValue - minValue + 1);
    }
}
