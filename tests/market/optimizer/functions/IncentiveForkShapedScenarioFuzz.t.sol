// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseLendingOptimizer} from "../TestBaseLendingOptimizer.sol";
import {LendingOptimizerHarness} from "../LendingOptimizerHarness.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    IChainlink
} from "contracts/interfaces/external/chainlink/IChainlink.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";
import {BPS, WAD} from "contracts/libraries/ConstantsLib.sol";

/// @notice Six-market fuzzing centered on the allocation and cap topology at
///         Monad block 75,302,964 for optimizer
///         0x37Bf94D8Af2Fbbf562Da5a3f1b0787b3515D10dd.
contract TestIncentiveForkShapedScenarioFuzz is TestBaseLendingOptimizer {
    struct Scenario {
        uint256[6] allocations;
        uint256[6] capsBps;
        uint256 incentiveTarget;
        uint256 incentiveBps;
        uint256 slippageBps;
        uint256 rebalanceChunks;
    }

    struct PolicyMasks {
        uint8 mintPause;
        uint8 redeemPause;
        uint8 bad;
    }

    uint256 internal constant MARKET_COUNT = 6;
    uint256 internal constant STALENESS_MULTIPLIER_BPS = 15_000;

    OptimizerReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)), 0
        );
    }

    function test_forkShape_exactPinnedAllocationAndCaps_allTargetsSafe()
        public
    {
        Scenario memory scenario;
        scenario.allocations =
            [uint256(0), 87_062_539, 0, 87_059_029, 29_018_236, 87_057_966];
        scenario.capsBps = [uint256(1_500), 3_500, 3_500, 3_500, 3_500, 3_500];
        scenario.incentiveBps = 1_000;
        scenario.slippageBps = 100;
        scenario.rebalanceChunks = 200;

        address[] memory markets = _setUpScenario(scenario);
        uint256 snapshotId = vm.snapshotState();
        uint256 nonemptyPlans;

        for (uint256 target; target < MARKET_COUNT; ++target) {
            if (_planAssertAndExecute(
                    markets,
                    target,
                    scenario.incentiveBps,
                    scenario.slippageBps,
                    scenario.rebalanceChunks,
                    PolicyMasks({mintPause: 0, redeemPause: 0, bad: 0})
                )) {
                ++nonemptyPlans;
            }

            assertTrue(
                vm.revertToState(snapshotId),
                "failed to restore exact fork-shaped state"
            );
            snapshotId = vm.snapshotState();
        }

        assertGt(nonemptyPlans, 0, "exact fork shape produced no plans");
    }

    function test_forkShape_liquidityConstrainedBadSourcePlanExecutes()
        public
    {
        Scenario memory scenario;
        scenario.allocations =
            [uint256(0), 600_000e6, 0, 150_000e6, 100_000e6, 150_000e6];
        scenario.capsBps = [uint256(3_500), 7_000, 3_500, 3_500, 3_500, 3_500];
        scenario.incentiveTarget = 0;
        scenario.incentiveBps = 1_000;
        scenario.slippageBps = 100;
        scenario.rebalanceChunks = 200;

        address[] memory markets = _setUpScenario(scenario);
        address constrainedSource = markets[1];

        // Allow enough collateral for the existing borrower to drain market
        // cash below the optimizer's position without introducing bad debt.
        _configureToken(
            MarketManagerIsolated(_marketMgrs[constrainedSource]),
            _collCTokens[constrainedSource],
            7_000,
            2_000_000e18,
            0
        );
        _seedAndBorrow(constrainedSource, 1e6, 400_000e6);

        IBorrowableCToken source = IBorrowableCToken(constrainedSource);
        uint256 sourcePosition =
            source.convertToAssets(source.balanceOf(address(optimizer)));
        assertLt(
            source.assetsHeld(),
            sourcePosition,
            "precondition: source cash must be below optimizer position"
        );

        uint8 badMask = uint8(1 << 1);
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            STALENESS_MULTIPLIER_BPS
        );
        _applyBadMask(markets, badMask);

        assertTrue(
            _planAssertAndExecute(
                markets,
                scenario.incentiveTarget,
                scenario.incentiveBps,
                scenario.slippageBps,
                scenario.rebalanceChunks,
                PolicyMasks({mintPause: 0, redeemPause: 0, bad: badMask})
            ),
            "liquidity-constrained bad source produced empty plan"
        );
    }

    function testFuzz_forkShape_healthyPlanExecutes(
        uint256 allocationSeed,
        uint256 capSeed,
        uint256 marketStateSeed,
        uint256 plannerSeed
    ) public {
        Scenario memory scenario = _buildScenario(
            allocationSeed, capSeed, plannerSeed
        );
        address[] memory markets = _setUpScenario(scenario);
        _applyMarketShocks(markets, marketStateSeed);

        _planAssertAndExecute(
            markets,
            scenario.incentiveTarget,
            scenario.incentiveBps,
            scenario.slippageBps,
            scenario.rebalanceChunks,
            PolicyMasks({mintPause: 0, redeemPause: 0, bad: 0})
        );
    }

    function testFuzz_forkShape_pausePolicyPlanExecutes(
        uint256 allocationSeed,
        uint256 capSeed,
        uint256 plannerSeed,
        uint8 mintPauseMask,
        uint8 redeemPauseMask
    ) public {
        Scenario memory scenario = _buildScenario(
            allocationSeed, capSeed, plannerSeed
        );
        address[] memory markets = _setUpScenario(scenario);
        mintPauseMask &= 0x3f;
        redeemPauseMask &= 0x3f;
        _applyPauseMasks(markets, mintPauseMask, redeemPauseMask);

        _planAssertAndExecute(
            markets,
            scenario.incentiveTarget,
            scenario.incentiveBps,
            scenario.slippageBps,
            scenario.rebalanceChunks,
            PolicyMasks({
                mintPause: mintPauseMask, redeemPause: redeemPauseMask, bad: 0
            })
        );
    }

    function testFuzz_forkShape_badAndPausedPolicyPlanExecutes(
        uint256 allocationSeed,
        uint256 capSeed,
        uint256 plannerSeed,
        uint8 badMask,
        uint8 mintPauseMask,
        uint8 redeemPauseMask
    ) public {
        Scenario memory scenario = _buildScenario(
            allocationSeed, capSeed, plannerSeed
        );
        address[] memory markets = _setUpScenario(scenario);
        badMask &= 0x3f;
        mintPauseMask &= 0x3f;
        redeemPauseMask &= 0x3f;

        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            STALENESS_MULTIPLIER_BPS
        );
        _applyBadMask(markets, badMask);
        _applyPauseMasks(markets, mintPauseMask, redeemPauseMask);

        _planAssertAndExecute(
            markets,
            scenario.incentiveTarget,
            scenario.incentiveBps,
            scenario.slippageBps,
            scenario.rebalanceChunks,
            PolicyMasks({
                mintPause: mintPauseMask,
                redeemPause: redeemPauseMask,
                bad: badMask
            })
        );
    }

    function testFuzz_forkShape_sparseMaxIncentiveIsNonemptyAndExecutes(
        uint256 allocationSeed,
        uint256 capSeed,
        uint256 plannerSeed,
        bool useSecondSparseMarket
    ) public {
        // Force the high-scale branch so filling even the smallest 10% cap
        // clears the reader's $100 rebalance threshold.
        Scenario memory scenario =
            _buildScenario(allocationSeed | 1, capSeed, plannerSeed);
        uint256 target = useSecondSparseMarket ? 2 : 0;
        scenario.allocations[5] += scenario.allocations[target];
        scenario.allocations[target] = 0;
        scenario.incentiveTarget = target;
        scenario.incentiveBps = 1_000;

        address[] memory markets = _setUpScenario(scenario);
        assertTrue(
            _planAssertAndExecute(
                markets,
                scenario.incentiveTarget,
                scenario.incentiveBps,
                scenario.slippageBps,
                scenario.rebalanceChunks,
                PolicyMasks({mintPause: 0, redeemPause: 0, bad: 0})
            ),
            "max incentive on sparse market produced empty plan"
        );
    }

    function _buildScenario(
        uint256 allocationSeed,
        uint256 capSeed,
        uint256 plannerSeed
    ) internal pure returns (Scenario memory scenario) {
        uint256 totalAssets;
        if (allocationSeed & 1 == 0) {
            totalAssets = _draw(
                allocationSeed, keccak256("low total assets"), 200e6, 2_000e6
            );
        } else {
            totalAssets = _draw(
                allocationSeed,
                keccak256("high total assets"),
                2_001e6,
                500_000e6
            );
        }

        uint256[6] memory weights;
        weights[0] = allocationSeed & 2 == 0
            ? 0
            : _draw(allocationSeed, keccak256("weight 0"), 1, 500);
        weights[1] = _draw(allocationSeed, keccak256("weight 1"), 2_000, 4_000);
        weights[2] = allocationSeed & 4 == 0
            ? 0
            : _draw(allocationSeed, keccak256("weight 2"), 1, 500);
        weights[3] = _draw(allocationSeed, keccak256("weight 3"), 2_000, 4_000);
        weights[4] = _draw(allocationSeed, keccak256("weight 4"), 500, 2_000);
        weights[5] = _draw(allocationSeed, keccak256("weight 5"), 2_000, 4_000);

        uint256 totalWeight;
        for (uint256 i; i < MARKET_COUNT; ++i) {
            totalWeight += weights[i];
        }

        uint256 allocated;
        for (uint256 i; i < MARKET_COUNT - 1; ++i) {
            scenario.allocations[i] = FixedPointMathLib.fullMulDiv(
                totalAssets, weights[i], totalWeight
            );
            allocated += scenario.allocations[i];
        }
        scenario.allocations[MARKET_COUNT - 1] = totalAssets - allocated;

        scenario.capsBps[0] = _draw(capSeed, keccak256("cap 0"), 1_000, 2_500);
        for (uint256 i = 1; i < MARKET_COUNT; ++i) {
            scenario.capsBps[i] =
                _draw(capSeed, keccak256(abi.encode("cap", i)), 3_000, 4_500);
        }

        scenario.incentiveTarget = _draw(
            plannerSeed, keccak256("incentive target"), 0, MARKET_COUNT - 1
        );
        scenario.incentiveBps =
            _draw(plannerSeed, keccak256("incentive bps"), 0, 1_000);
        scenario.slippageBps =
            _draw(plannerSeed, keccak256("slippage"), 0, 1_000);
        scenario.rebalanceChunks =
            _draw(plannerSeed, keccak256("chunks"), 1, 500);
    }

    function _setUpScenario(Scenario memory scenario)
        internal
        returns (address[] memory markets)
    {
        markets = new address[](MARKET_COUNT);
        markets[0] = cUSDC_WMON_MARKET;
        markets[1] = cUSDC_WBTC_MARKET;
        markets[2] = cUSDC_WETH_MARKET;
        markets[3] = _deployMarket(700, 2_100, 8_200, 900, 125, 100_000);
        markets[4] = _deployMarket(900, 2_300, 8_000, 800, 150, 100_000);
        markets[5] = _deployMarket(500, 2_500, 8_400, 1_100, 100, 100_000);

        _seedAndBorrow(markets[3], 500_000e6, 180_000e6);
        _seedAndBorrow(markets[4], 500_000e6, 80_000e6);
        _seedAndBorrow(markets[5], 500_000e6, 120_000e6);

        uint256[] memory caps = new uint256[](MARKET_COUNT);
        for (uint256 i; i < MARKET_COUNT; ++i) {
            caps[i] = scenario.capsBps[i];
        }

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD), liveCentralRegistry, markets, caps, 0
        );
        assertEq(optimizer.numApprovedMarkets(), MARKET_COUNT, "market count");

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(optimizer), 77777);
        optimizer.initializeDeposits(markets[0]);

        uint256 totalDeposits;
        for (uint256 i; i < MARKET_COUNT; ++i) {
            totalDeposits += scenario.allocations[i];
        }
        deal(USDC_MONAD, address(this), totalDeposits);
        IERC20(USDC_MONAD).approve(address(optimizer), totalDeposits);
        for (uint256 i; i < MARKET_COUNT; ++i) {
            if (scenario.allocations[i] == 0) continue;
            LendingOptimizerHarness(address(optimizer))
                .depositToMarket(
                    scenario.allocations[i], address(this), markets[i]
                );
        }

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
    }

    function _applyMarketShocks(address[] memory markets, uint256 seed)
        internal
    {
        uint256[6] memory initialBorrows = [
            uint256(100_000e6),
            200_000e6,
            150_000e6,
            180_000e6,
            80_000e6,
            120_000e6
        ];

        for (uint256 i; i < MARKET_COUNT; ++i) {
            uint256 mode =
                _draw(seed, keccak256(abi.encode("shock mode", i)), 0, 3);

            if (mode == 1 || mode == 3) {
                uint256 liquidity = _draw(
                    seed,
                    keccak256(abi.encode("external liquidity", i)),
                    1_000e6,
                    2_000_000e6
                );
                address lender = address(uint160(0xA000 + i));
                deal(USDC_MONAD, lender, liquidity);
                vm.startPrank(lender);
                IERC20(USDC_MONAD).approve(markets[i], liquidity);
                IBorrowableCToken(markets[i]).deposit(liquidity, lender);
                vm.stopPrank();
            }

            if (mode == 2 || mode == 3) {
                uint256 additionalBorrow = _draw(
                    seed,
                    keccak256(abi.encode("additional borrow", i)),
                    1e6,
                    initialBorrows[i] / 2
                );
                address borrower = address(
                    uint160(
                        uint256(keccak256(abi.encode("borrower", markets[i])))
                    )
                );
                vm.prank(borrower);
                IBorrowableCToken(markets[i])
                    .borrow(additionalBorrow, borrower);
            }
        }
    }

    function _applyPauseMasks(
        address[] memory markets,
        uint8 mintPauseMask,
        uint8 redeemPauseMask
    ) internal {
        for (uint256 i; i < MARKET_COUNT; ++i) {
            MarketManagerIsolated manager =
                MarketManagerIsolated(_marketMgrs[markets[i]]);
            if (mintPauseMask & uint8(1 << i) != 0) {
                manager.setMintPaused(markets[i], true);
            }
            if (redeemPauseMask & uint8(1 << i) != 0) {
                manager.setRedeemPaused(true);
            }
        }
    }

    function _applyBadMask(address[] memory markets, uint8 badMask) internal {
        vm.warp(block.timestamp + 2 days);

        (, IChainlink underlyingAggregator,,) =
            _chainlinkAdaptor.assetConfig(USDC_MONAD, true);
        MockV3Aggregator(address(underlyingAggregator)).updateAnswer(1e8);

        for (uint256 i; i < MARKET_COUNT; ++i) {
            if (badMask & uint8(1 << i) != 0) continue;

            (, IChainlink collateralAggregator,,) =
                _chainlinkAdaptor.assetConfig(_collaterals[markets[i]], true);
            MockV3Aggregator(address(collateralAggregator)).updateAnswer(1e8);
        }
    }

    function _planAssertAndExecute(
        address[] memory markets,
        uint256 incentiveTarget,
        uint256 incentiveBps,
        uint256 slippageBps,
        uint256 rebalanceChunks,
        PolicyMasks memory policy
    ) internal returns (bool nonempty) {
        OptimizerReader.MarketIncentiveAPYBps[] memory
            incentives = new OptimizerReader.MarketIncentiveAPYBps[](1);
        incentives[0] = OptimizerReader.MarketIncentiveAPYBps({
            cToken: markets[incentiveTarget], incentiveAPYBps: incentiveBps
        });

        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalanceWithIncentives(
            address(optimizer), slippageBps, rebalanceChunks, incentives
        );

        assertEq(actions.length, bounds.length, "actions/bounds length");
        if (actions.length == 0) return false;
        assertEq(actions.length, MARKET_COUNT, "nonempty action length");

        uint256[] memory currentAssets = _marketAssets(markets);
        uint256[] memory projectedAssets =
            _assertActionsAndProject(markets, actions, currentAssets, policy);
        _assertProjectedCapsAndBounds(
            markets, bounds, projectedAssets, slippageBps
        );

        optimizer.rebalance(actions, bounds);
        _assertActualPostState(markets, bounds, projectedAssets);
        return true;
    }

    function _assertActionsAndProject(
        address[] memory markets,
        LendingOptimizer.ReallocationAction[] memory actions,
        uint256[] memory currentAssets,
        PolicyMasks memory policy
    ) internal view returns (uint256[] memory projectedAssets) {
        uint256 deposits;
        uint256 withdrawals;
        projectedAssets = new uint256[](MARKET_COUNT);

        for (uint256 i; i < MARKET_COUNT; ++i) {
            assertEq(address(actions[i].cToken), markets[i], "action order");

            int256 delta = actions[i].assetsOrBps;
            if (policy.redeemPause & uint8(1 << i) != 0) {
                assertEq(delta, 0, "redeem-paused market moved");
            } else if (policy.mintPause & uint8(1 << i) != 0) {
                assertLe(delta, 0, "mint-paused market received assets");
            }
            if (policy.bad & uint8(1 << i) != 0) {
                assertLe(delta, 0, "bad market received assets");
            }

            if (delta != 0) {
                uint256 amount = delta > 0 ? uint256(delta) : uint256(-delta);
                assertGt(
                    IBorrowableCToken(markets[i]).convertToShares(amount),
                    0,
                    "dust action"
                );
                if (delta > 0) {
                    deposits += amount;
                } else {
                    withdrawals += amount;
                    assertLe(amount, currentAssets[i], "withdraw > position");
                    assertLe(
                        amount,
                        IBorrowableCToken(markets[i]).assetsHeld(),
                        "withdraw > cash"
                    );
                }
            }

            projectedAssets[i] = _previewPostActionAssets(
                actions[i].cToken, currentAssets[i], delta
            );
        }

        assertEq(deposits, withdrawals, "plan must balance exactly");
    }

    function _assertProjectedCapsAndBounds(
        address[] memory markets,
        LendingOptimizer.AllocationBound[] memory bounds,
        uint256[] memory projectedAssets,
        uint256 slippageBps
    ) internal view {
        uint256 projectedTotal;
        for (uint256 i; i < MARKET_COUNT; ++i) {
            projectedTotal += projectedAssets[i];
        }

        for (uint256 i; i < MARKET_COUNT; ++i) {
            assertEq(bounds[i].cToken, markets[i], "bound order");
            uint256 allocationWad = FixedPointMathLib.fullMulDiv(
                projectedAssets[i], WAD, projectedTotal
            );
            assertLe(
                allocationWad,
                optimizer.allocationCaps(markets[i]),
                "projected allocation exceeds cap"
            );

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
                uint256 room = BPS - expectedMax;
                expectedMax += slippageBps < room ? slippageBps : room;
            }

            assertEq(bounds[i].minBps, expectedMin, "bound min");
            assertEq(bounds[i].maxBps, expectedMax, "bound max");
        }
    }

    function _assertActualPostState(
        address[] memory markets,
        LendingOptimizer.AllocationBound[] memory bounds,
        uint256[] memory projectedAssets
    ) internal view {
        uint256[] memory actualAssets = _marketAssets(markets);
        uint256 actualTotal;
        for (uint256 i; i < MARKET_COUNT; ++i) {
            actualTotal += actualAssets[i];
        }

        assertEq(optimizer.totalAssets(), actualTotal, "accounting drift");
        for (uint256 i; i < MARKET_COUNT; ++i) {
            assertEq(
                actualAssets[i], projectedAssets[i], "projection != execution"
            );

            uint256 allocationWad = FixedPointMathLib.fullMulDiv(
                actualAssets[i], WAD, actualTotal
            );
            assertLe(
                allocationWad,
                optimizer.allocationCaps(markets[i]),
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
            uint256 assets = uint256(delta);
            uint256 shares = cToken.previewDeposit(assets);
            return FixedPointMathLib.fullMulDiv(
                currentShares + shares,
                cToken.totalAssets() + assets,
                cToken.totalSupply() + shares
            );
        }

        if (delta < 0) {
            uint256 assets = uint256(-delta);
            uint256 shares = cToken.previewWithdraw(assets);
            if (shares >= currentShares || shares >= cToken.totalSupply()) {
                return 0;
            }
            return FixedPointMathLib.fullMulDiv(
                currentShares - shares,
                cToken.totalAssets() - assets,
                cToken.totalSupply() - shares
            );
        }

        return currentAssets;
    }

    function _marketAssets(address[] memory markets)
        internal
        view
        returns (uint256[] memory assets)
    {
        assets = new uint256[](MARKET_COUNT);
        for (uint256 i; i < MARKET_COUNT; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(markets[i]);
            assets[i] =
                cToken.convertToAssets(cToken.balanceOf(address(optimizer)));
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
