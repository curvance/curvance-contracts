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
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Bad-Market x Pause-State Combination Tests
/// @notice Regression coverage for the interaction between `isBad()` flagging
///         and market-level pause state in `_computeIdealAllocation`. Prior
///         to the fix, a market that was simultaneously flagged bad and had
///         `redeemPaused == 2` produced a full-withdrawal action whose
///         execution would revert with `LendingOptimizer__MarketPaused`,
///         blocking rebalancing of the remaining healthy markets. Post-fix,
///         such a market is frozen in place and the healthy markets
///         rebalance normally.
contract TestBadMarketPausedCombination is TestBaseLendingOptimizer {

    OptimizerReader reader;

    /// @dev Default heartbeat stored by ChainlinkAdaptor when 0 is passed:
    ///      1 days + HEARTBEAT_GRACE_PERIOD (120) = 86520 seconds.
    uint256 constant DEFAULT_HEARTBEAT = 86520;
    uint256 constant MULTIPLIER_1_5X = 15000;
    uint256 constant THRESHOLD_1_5X = DEFAULT_HEARTBEAT * MULTIPLIER_1_5X / 10000;

    function setUp() public override {
        super.setUp();
        reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            MULTIPLIER_1_5X
        );
    }

    // ============================================================
    // bad + redeem-paused: the previously-broken case
    // ============================================================

    /// @notice Bad market that is also redeem-paused must not receive a
    ///         withdrawal action — it is frozen in place.
    function test_badAndRedeemPaused_noWithdrawalAction() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        // Stale only market 0's collateral feed.
        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        // Pause market 0 for redemptions via its market manager.
        _mockRedeemPaused(cUSDC_WMON_MARKET);

        // Sanity check: market 0 is flagged bad.
        address[] memory bad = reader.isBad(address(optimizer));
        assertEq(bad.length, 1, "Exactly one market flagged bad");
        assertEq(bad[0], cUSDC_WMON_MARKET, "Market 0 (WMON) is the bad one");

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        if (actions.length > 0) {
            assertEq(
                actions[0].assetsOrBps,
                int256(0),
                "Bad+redeemPaused market must produce no action"
            );
        }
    }

    /// @notice End-to-end: a bad+redeemPaused market does not block
    ///         rebalancing of the healthy markets. This is the core
    ///         regression — before the fix this tx reverted with
    ///         `LendingOptimizer__MarketPaused`.
    function test_badAndRedeemPaused_rebalanceExecutesOnHealthyMarkets() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        // Create a rate imbalance between markets 1 and 2 to give the
        // rebalance something to do on the healthy pair.
        _floodMarket(cUSDC_WETH_MARKET, 3_000_000e6);

        // Bad + paused on market 0.
        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);
        _mockRedeemPaused(cUSDC_WMON_MARKET);

        optimizer.accrueIfNeeded();

        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500);

        // Should not revert.
        if (actions.length > 0) {
            optimizer.rebalance(actions, bounds);
        }
    }

    /// @notice Bad+redeemPaused market's cToken shares remain untouched —
    ///         the rebalance neither withdraws nor deposits. We check
    ///         shares (not asset value) because the underlying cToken
    ///         continues to accrue interest on other borrowers' debt
    ///         during the skip(); that accrual is orthogonal to the
    ///         frozen-position invariant we want to assert here.
    function test_badAndRedeemPaused_badMarketSharesFrozen() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        // Create a rate imbalance between the healthy markets to
        // motivate a non-trivial rebalance.
        _floodMarket(cUSDC_WETH_MARKET, 3_000_000e6);

        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);
        _mockRedeemPaused(cUSDC_WMON_MARKET);

        optimizer.accrueIfNeeded();

        // Snapshot shares immediately before the rebalance.
        uint256 sharesBefore = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        assertGt(sharesBefore, 0, "Market 0 should hold cToken shares");

        _executeOptimalRebalance();

        uint256 sharesAfter = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));

        assertEq(
            sharesAfter,
            sharesBefore,
            "Bad+redeemPaused market cToken shares must be frozen"
        );
    }

    /// @notice When a bad+redeemPaused market is present, healthy markets
    ///         still rebalance among themselves (the fix preserves utility).
    function test_badAndRedeemPaused_healthyMarketsStillRebalance() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        // Strong rate imbalance between markets 1 and 2.
        _floodMarket(cUSDC_WETH_MARKET, 5_000_000e6);

        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);
        _mockRedeemPaused(cUSDC_WMON_MARKET);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        if (actions.length > 0) {
            // Market 0 frozen.
            assertEq(actions[0].assetsOrBps, int256(0), "Market 0 frozen");
            // Markets 1 and 2 sum to zero-sum (no overall deposit/withdraw).
            int256 movement = actions[1].assetsOrBps + actions[2].assetsOrBps;
            assertEq(movement, int256(0), "Healthy pair must zero-sum");
            // Some actual movement happened.
            assertTrue(
                actions[1].assetsOrBps != 0 || actions[2].assetsOrBps != 0,
                "Healthy markets should have rebalanced"
            );
        }
    }

    // ============================================================
    // bad + mint-paused (redeem OK): drains normally
    // ============================================================

    /// @notice Bad market that is mint-paused but NOT redeem-paused can
    ///         still be drained via withdrawal — the pre-existing drain
    ///         behavior is preserved when redemption is possible.
    function test_badAndMintPausedRedeemable_drains() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        // mint-paused only (redeem is not paused).
        _mockMintPaused(cUSDC_WMON_MARKET);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        assertTrue(actions.length > 0, "Should produce actions");
        assertLt(
            actions[0].assetsOrBps,
            int256(0),
            "Bad+mintPaused (redeemable) must be drained via withdrawal"
        );
    }

    // ============================================================
    // bad + both paused: freeze in place
    // ============================================================

    /// @notice Bad market that is both mint- and redeem-paused → frozen.
    function test_badAndBothPaused_frozen() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        _mockRedeemPaused(cUSDC_WMON_MARKET);
        _mockMintPaused(cUSDC_WMON_MARKET);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        if (actions.length > 0) {
            assertEq(
                actions[0].assetsOrBps,
                int256(0),
                "Bad+bothPaused market must be frozen"
            );
        }
    }

    // ============================================================
    // bad + no pause: drains (pre-existing behavior unchanged)
    // ============================================================

    /// @notice Bad market with no pauses still gets drained — the fix
    ///         must not regress this pre-existing path.
    function test_badOnly_drains() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        skip(THRESHOLD_1_5X + 1);
        _refreshCollateralFeed(cUSDC_WBTC_MARKET);
        _refreshCollateralFeed(cUSDC_WETH_MARKET);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        assertTrue(actions.length > 0, "Should produce actions");
        assertLt(
            actions[0].assetsOrBps,
            int256(0),
            "Bad (not paused) market must be drained"
        );
    }

    // ============================================================
    // not bad + redeem-paused: pre-existing behavior unchanged
    // ============================================================

    /// @notice Non-bad redeem-paused market is frozen — baseline behavior
    ///         must not regress.
    function test_notBadAndRedeemPaused_stillFrozen() public {
        _setUpThreeMarketsUnconstrained();
        _depositToAllMarketsUnconstrained(100_000e6);

        // No staleness. Only pause market 0's redeem.
        _mockRedeemPaused(cUSDC_WMON_MARKET);

        // Motivate a rebalance between the other markets.
        _floodMarket(cUSDC_WETH_MARKET, 3_000_000e6);

        (LendingOptimizer.ReallocationAction[] memory actions, ) =
            reader.optimalRebalance(address(optimizer), 500);

        if (actions.length > 0) {
            // No withdrawal from the paused market.
            assertGe(
                actions[0].assetsOrBps,
                int256(0),
                "Redeem-paused market must not be withdrawn from"
            );
        }
    }

    // ============================================================
    // internal helpers
    // ============================================================

    function _mockRedeemPaused(address market) internal {
        address mm = address(IBorrowableCToken(market).marketManager());
        vm.mockCall(
            mm,
            abi.encodeWithSelector(bytes4(keccak256("redeemPaused()"))),
            abi.encode(uint8(2))
        );
    }

    function _mockMintPaused(address market) internal {
        address mm = address(IBorrowableCToken(market).marketManager());
        vm.mockCall(
            mm,
            abi.encodeWithSelector(IMarketManager.actionsPaused.selector, market),
            abi.encode(true, false, false)
        );
    }

    function _floodMarket(address market, uint256 amount) internal {
        address whale = address(0xBEEF);
        deal(USDC_MONAD, whale, amount);
        vm.startPrank(whale);
        IERC20(USDC_MONAD).approve(market, amount);
        IBorrowableCToken(market).deposit(amount, whale);
        vm.stopPrank();
    }

    function _refreshCollateralFeed(address market) internal {
        address collAsset = _collaterals[market];
        (, IChainlink aggregator,, ) = _chainlinkAdaptor.assetConfig(collAsset, true);
        MockV3Aggregator(address(aggregator)).updateAnswer(1e8);
    }

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

    function _depositToAllMarketsUnconstrained(uint256 amountPerMarket) internal {
        address[3] memory markets = [
            cUSDC_WMON_MARKET,
            cUSDC_WBTC_MARKET,
            cUSDC_WETH_MARKET
        ];

        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), amountPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), amountPerMarket);
            LendingOptimizerHarness(address(optimizer)).depositToMarket(
                amountPerMarket, address(this), markets[i]
            );
        }
    }

    function _executeOptimalRebalance() internal {
        (LendingOptimizer.ReallocationAction[] memory actions,
         LendingOptimizer.AllocationBound[] memory bounds) =
            reader.optimalRebalance(address(optimizer), 500);
        if (actions.length > 0) optimizer.rebalance(actions, bounds);
    }
}
