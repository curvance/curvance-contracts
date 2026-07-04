// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";

/// @title Oracle Staleness Tests
/// @notice Tests the staleness check in isBad: when a collateral asset's
///         oracle feed hasn't updated within heartbeat * multiplierBps / 10000,
///         the market is flagged as bad and excluded from rebalance.
contract TestOracleStaleness is TestBaseLendingOptimizer {

    OptimizerReader reader;

    /// @dev Default heartbeat stored by ChainlinkAdaptor when 0 is passed:
    ///      1 days + HEARTBEAT_GRACE_PERIOD (120) = 86520 seconds.
    uint256 constant DEFAULT_HEARTBEAT = 86520;

    /// @dev 1.5x multiplier in BPS.
    uint256 constant MULTIPLIER_1_5X = 15000;

    /// @dev Staleness threshold at 1.5x = 86520 * 15000 / 10000 = 129780 seconds.
    uint256 constant THRESHOLD_1_5X = DEFAULT_HEARTBEAT * MULTIPLIER_1_5X / 10000;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            MULTIPLIER_1_5X
        );
    }

    // ==================== isBad: Fresh Feeds ====================

    /// @notice With fresh feeds, no markets are flagged.
    function test_isBad_staleness_freshFeeds_noBadMarkets() public {
        _setUpThreeMarketsUnconstrained();

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 0, "Fresh feeds should not flag any markets");
    }

    // ==================== isBad: Stale Feeds ====================

    /// @notice Skipping past the threshold makes all markets stale.
    function test_isBad_staleness_allStale_allFlagged() public {
        _setUpThreeMarketsUnconstrained();

        // Skip past 1.5x heartbeat.
        skip(THRESHOLD_1_5X + 1);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 3, "All markets should be flagged when all feeds are stale");
    }

    function test_optimalRebalance_staleness_allStale_returnsEmpty() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        skip(THRESHOLD_1_5X + 1);

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        assertEq(actions.length, 0, "No executable rebalance when every market is stale");
        assertEq(bounds.length, 0, "No bounds when every market is stale");
    }

    /// @notice Only the market with a stale collateral feed is flagged.
    function test_isBad_staleness_oneStale_onlyThatFlagged() public {
        _setUpThreeMarketsUnconstrained();

        // Skip past threshold — all feeds now stale.
        skip(THRESHOLD_1_5X + 1);

        // Refresh feeds for markets 1 and 2.
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 1, "Only one market should be flagged");
        assertEq(bad[0], cUSDC_WMON_MARKET, "Stale market should be market 0");
    }

    /// @notice Two stale, one fresh.
    function test_isBad_staleness_twoStale_twoFlagged() public {
        _setUpThreeMarketsUnconstrained();

        skip(THRESHOLD_1_5X + 1);

        // Refresh only market 1.
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 2, "Two markets should be flagged");
    }

    // ==================== Disabled When Multiplier Is Zero ====================

    /// @notice With multiplier = 0, staleness checking is disabled.
    function test_isBad_staleness_disabled_whenMultiplierZero() public {
        // Deploy a reader with staleness disabled.
        OptimizerReader readerNoStaleness = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            0
        );

        _setUpThreeMarketsUnconstrained();

        // Skip way past any reasonable threshold.
        skip(30 days);

        address[] memory bad = readerNoStaleness.isBad(address(optimizer));
        assertEq(bad.length, 0, "Staleness disabled: no markets should be flagged");
    }

    // ==================== Boundary Tests ====================

    /// @notice Exactly at threshold: not stale (needs to exceed, not equal).
    function test_isBad_staleness_exactlyAtThreshold_notStale() public {
        _setUpThreeMarketsUnconstrained();

        // The feeds were created during setUp. Account for time already
        // elapsed during setUp (~3603s from _seedAndBorrow warps).
        // Feed updatedAt is approximately setUp start time.
        // Current block.timestamp is setUp start + ~3603s.
        // We need to skip so that total elapsed == THRESHOLD_1_5X exactly.
        // Since some time already passed, skip the remaining.
        uint256 feedAge = _collateralFeedAge(cUSDC_WMON_MARKET);
        uint256 remaining = THRESHOLD_1_5X - feedAge;
        skip(remaining);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 0, "Exactly at threshold should not be stale");
    }

    /// @notice One second past threshold: stale.
    function test_isBad_staleness_oneSecondPastThreshold_stale() public {
        _setUpThreeMarketsUnconstrained();

        uint256 feedAge = _collateralFeedAge(cUSDC_WMON_MARKET);
        uint256 remaining = THRESHOLD_1_5X - feedAge;
        skip(remaining + 1);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 3, "One second past threshold should be stale");
    }

    /// @notice A future-dated feed is treated as stale instead of reverting.
    function test_isBad_staleness_futureDatedFeed_flagsMarketWithoutRevert()
        public
    {
        _setUpThreeMarketsUnconstrained();

        _futureDateCollateralFeed(cUSDC_WMON_MARKET);

        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 1, "Only future-dated market should be flagged");
        assertEq(bad[0], cUSDC_WMON_MARKET);
    }

    function test_isBad_staleness_nonChainlinkPrimaryAdaptorRevertsAsConfigCaveat()
        public
    {
        _setUpThreeMarketsUnconstrained();

        address collAsset = _collaterals[cUSDC_WMON_MARKET];
        MockOracleAdaptor mockAdaptor = new MockOracleAdaptor(
            liveCentralRegistry,
            "MockOracleAdaptor"
        );
        _oracleManager.addApprovedAdaptor(address(mockAdaptor));
        mockAdaptor.addAsset(collAsset);
        mockAdaptor.setPrice(collAsset, 1e18, 1e18);
        _oracleManager.replaceAssetPricingAdaptor(
            collAsset,
            address(_chainlinkAdaptor),
            address(mockAdaptor),
            0,
            0,
            0,
            0
        );

        vm.expectRevert();
        reader.isBad(address(optimizer));
    }

    function test_isBad_staleness_missingPricingAdaptorRevertsAsConfigCaveat()
        public
    {
        _setUpThreeMarketsUnconstrained();

        address collAsset = _collaterals[cUSDC_WMON_MARKET];
        _oracleManager.removeAssetPricingAdaptor(
            collAsset,
            address(_chainlinkAdaptor)
        );

        vm.expectRevert();
        reader.isBad(address(optimizer));
    }

    // ==================== Feed Refreshed ====================

    /// @notice A stale feed that gets updated is no longer flagged.
    function test_isBad_staleness_feedRefreshed_noLongerStale() public {
        _setUpThreeMarketsUnconstrained();

        // Make all stale.
        skip(THRESHOLD_1_5X + 1);

        address[] memory badBefore = reader.isBad(address(optimizer));
        assertEq(badBefore.length, 3, "All should be stale before refresh");

        // Refresh all feeds.
        _refreshCollateralFeed(cUSDC_WMON_MARKET);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        address[] memory badAfter = reader.isBad(address(optimizer));
        assertEq(badAfter.length, 0, "No markets should be stale after refresh");
    }

    // ==================== Different Multiplier Values ====================

    /// @notice 1x multiplier (10000 BPS) — stale exactly at heartbeat.
    function test_isBad_staleness_1xMultiplier() public {
        OptimizerReader reader1x = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            10000 // 1x
        );

        _setUpThreeMarketsUnconstrained();

        uint256 threshold1x = DEFAULT_HEARTBEAT;
        uint256 feedAge = _collateralFeedAge(cUSDC_WMON_MARKET);

        // Just under 1x threshold: not stale.
        skip(threshold1x - feedAge);
        assertEq(reader1x.isBad(address(optimizer)).length, 0, "Under 1x: not stale");

        // Push past.
        skip(1);
        assertEq(reader1x.isBad(address(optimizer)).length, 3, "Past 1x: stale");
    }

    /// @notice 3x multiplier (30000 BPS).
    function test_isBad_staleness_3xMultiplier() public {
        OptimizerReader reader3x = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            30000 // 3x
        );

        _setUpThreeMarketsUnconstrained();

        uint256 threshold3x = DEFAULT_HEARTBEAT * 3;

        // Past 1.5x but under 3x: not stale with 3x multiplier.
        skip(THRESHOLD_1_5X + 1);
        assertEq(reader3x.isBad(address(optimizer)).length, 0, "Under 3x: not stale");

        // Push past 3x.
        uint256 feedAge = _collateralFeedAge(cUSDC_WMON_MARKET);
        skip(threshold3x - feedAge + 1);
        assertEq(reader3x.isBad(address(optimizer)).length, 3, "Past 3x: stale");
    }

    // ==================== setStalenessMultiplier ====================

    /// @notice Setter updates value and emits event.
    function test_setStalenessMultiplier_success() public {
        assertEq(reader.stalenessMultiplierBps(), MULTIPLIER_1_5X);

        vm.expectEmit();
        emit OptimizerReader.StalenessMultiplierUpdated(MULTIPLIER_1_5X, 20000);
        reader.setStalenessMultiplier(20000);

        assertEq(reader.stalenessMultiplierBps(), 20000);
    }

    /// @notice Can disable staleness checking by setting to 0.
    function test_setStalenessMultiplier_disables() public {
        _setUpThreeMarketsUnconstrained();
        skip(THRESHOLD_1_5X + 1);

        // Stale with current multiplier.
        assertEq(reader.isBad(address(optimizer)).length, 3);

        // Disable.
        reader.setStalenessMultiplier(0);
        assertEq(reader.isBad(address(optimizer)).length, 0, "Disabled: no stale markets");
    }

    /// @notice Unauthorized caller reverts.
    function test_setStalenessMultiplier_fail_unauthorized() public {
        address nobody = address(0xDEAD);
        vm.prank(nobody);
        vm.expectRevert(OptimizerReader.OptimizerReader__Unauthorized.selector);
        reader.setStalenessMultiplier(20000);
    }

    /// @notice Multiplier between 1 and 9999 (sub-1x) reverts.
    function test_setStalenessMultiplier_fail_subOneMultiplier() public {
        vm.expectRevert(OptimizerReader.OptimizerReader__InvalidMultiplier.selector);
        reader.setStalenessMultiplier(5000);
    }

    /// @notice Boundary: 9999 reverts, 10000 succeeds.
    function test_setStalenessMultiplier_boundary() public {
        vm.expectRevert(OptimizerReader.OptimizerReader__InvalidMultiplier.selector);
        reader.setStalenessMultiplier(9999);

        // 10000 (1x) should succeed.
        reader.setStalenessMultiplier(10000);
        assertEq(reader.stalenessMultiplierBps(), 10000);

        // 0 (disabled) should succeed.
        reader.setStalenessMultiplier(0);
        assertEq(reader.stalenessMultiplierBps(), 0);
    }

    // ==================== multiIsBadCheck ====================

    /// @notice Batch staleness check across multiple optimizers.
    function test_multiIsBadCheck_withStaleness() public {
        _setUpThreeMarketsUnconstrained();

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);

        // Fresh: no bad.
        address[][] memory results = reader.multiIsBadCheck(optimizers);
        assertEq(results[0].length, 0);

        // Stale: all bad.
        skip(THRESHOLD_1_5X + 1);
        results = reader.multiIsBadCheck(optimizers);
        assertEq(results[0].length, 3, "All markets should be flagged in batch check");
    }

    // ==================== Integration: Stale Market Excluded ====================

    /// @notice A stale market is excluded from the optimal allocation
    ///         (defensive exit), same as a price guard breach.
    function test_staleness_integration_staleMarketExcludedFromRebalance() public {
        _setUpThreeMarketsUnconstrained();

        // Deposit evenly.
        _depositToAllMarketsUnconstrained(100_000e6);

        // Make only market 0's feed stale.
        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        // optimalRebalance should defensively exit market 0.
        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        assertTrue(actions.length > 0, "Should have rebalance actions");

        // Market 0 should have a withdrawal (negative action).
        assertLt(
            actions[0].assetsOrBps,
            0,
            "Stale market should have withdrawal action"
        );

        // At least one good market should receive deposits.
        bool hasDeposit;
        for (uint256 i = 1; i < actions.length; ++i) {
            if (actions[i].assetsOrBps > 0) {
                hasDeposit = true;
                break;
            }
        }
        assertTrue(hasDeposit, "Good markets should receive deposits");
    }

    /// @notice Stale market defensive rebalance is executable.
    function test_staleness_integration_defensiveRebalanceExecutable() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        // Make market 0 stale.
        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        // Accrue before measuring so the rebalance doesn't shift totalAssets.
        optimizer.accrueIfNeeded();

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        uint256 totalAssetsBefore = optimizer.totalAssets();

        if (actions.length > 0) {
            optimizer.rebalance(actions, bounds);
        }

        assertApproxEqAbs(
            optimizer.totalAssets(),
            totalAssetsBefore,
            actions.length * 2,
            "Total assets should be preserved after defensive rebalance"
        );

        // Stale market should be near-empty (within 1 chunk from rounding).
        uint256 oneChunk = optimizer.totalAssets() / 20;
        assertLe(
            IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
                IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
            ),
            oneChunk,
            "Stale market should be near-empty after defensive rebalance"
        );
    }

    /// @notice After feed recovers, next rebalance re-enters the market.
    function test_staleness_integration_recoveryReEntersMarket() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        // Stale market 0 and defensively exit.
        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        optimizer.accrueIfNeeded();

        (LendingOptimizer.ReallocationAction[] memory actions1,
         LendingOptimizer.AllocationBound[] memory bounds1) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        if (actions1.length > 0) {
            optimizer.rebalance(actions1, bounds1);
        }

        // Market 0 should be near-empty (within 1 chunk from rounding).
        uint256 oneChunk = optimizer.totalAssets() / 20;
        uint256 m0AllocAfterExit = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        assertLe(m0AllocAfterExit, oneChunk, "Market 0 should be near-empty");

        // Refresh market 0's feed -- it recovers.
        _refreshCollateralFeed(cUSDC_WMON_MARKET);

        // Next rebalance should re-enter market 0.
        (LendingOptimizer.ReallocationAction[] memory actions2,
         LendingOptimizer.AllocationBound[] memory bounds2) =
            reader.optimalRebalance(address(optimizer), 500, 200);

        if (actions2.length > 0) {
            optimizer.rebalance(actions2, bounds2);

            uint256 m0AllocAfterRecovery = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
                IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
            );
            assertGt(m0AllocAfterRecovery, m0AllocAfterExit, "Market 0 should have assets after recovery");
        }
    }

    // ==================== Internal Helpers ====================

    /// @dev Refreshes a market's collateral oracle feed by calling updateAnswer
    ///      on its MockV3Aggregator, which sets updatedAt = block.timestamp.
    function _refreshCollateralFeed(address market) internal {
        address collAsset = _collaterals[market];
        (, IChainlink aggregator,, ) = _chainlinkAdaptor.assetConfig(collAsset, true);
        MockV3Aggregator(address(aggregator)).updateAnswer(1e8);
    }

    /// @dev Returns how many seconds have elapsed since the collateral feed
    ///      was last updated.
    function _collateralFeedAge(address market) internal view returns (uint256) {
        address collAsset = _collaterals[market];
        (, IChainlink aggregator,, ) = _chainlinkAdaptor.assetConfig(collAsset, true);
        (,,, uint256 updatedAt,) = aggregator.latestRoundData();
        return block.timestamp - updatedAt;
    }

    function _futureDateCollateralFeed(address market) internal {
        address collAsset = _collaterals[market];
        (, IChainlink aggregator,, ) = _chainlinkAdaptor.assetConfig(collAsset, true);
        (uint80 roundId,,,,) = aggregator.latestRoundData();
        MockV3Aggregator(address(aggregator)).updateRoundData(
            roundId + 1,
            1e8,
            block.timestamp + 1 hours,
            block.timestamp + 1 hours
        );
    }

    /// @dev Sets up 3 markets with 100% caps and harvest permissions.
    function _setUpThreeMarketsUnconstrained() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

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
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasHarvestPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
    }

    /// @dev Deposits the same amount into each of the 3 markets.
    function _depositToAllMarketsUnconstrained(uint256 amountPerMarket) internal {
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];

        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), amountPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), amountPerMarket);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(
                amountPerMarket, address(this), markets[i]
            );
        }
    }
}
