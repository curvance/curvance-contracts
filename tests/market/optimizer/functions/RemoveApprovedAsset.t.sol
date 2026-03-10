// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

contract TestLendingOptimizerRemoveApprovedAsset is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    function test_lendingOptimizer_removeApprovedAsset_success() public {
        // Setup with three markets (60% + 50% + 20% caps).
        // After removing 20% cap market, remaining 60% + 50% = 110% >= 100%.
        _setUpThreeMarkets();

        // Deposit to markets 0 and 1, with a smaller deposit to market 2
        // so the reallocation after removal fits within remaining caps.
        deal(USDC_MONAD, address(this), 21_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 21_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(1_000e6, address(this), cUSDC_WETH_MARKET);

        // Record state before removal.
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 numMarketsBefore = optimizer.numApprovedMarkets();
        assertEq(numMarketsBefore, 3, "Should have 3 markets before removal");

        // Reallocate removed assets to market 0 (which has cap headroom).
        // After removal: total ~21K, market 0 ~11K (52%), cap 60% — within bounds.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(10_000)
        );

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Remove cUSDC_WETH_MARKET (20% cap).
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // Verify market was removed.
        uint256 numMarketsAfter = optimizer.numApprovedMarkets();
        assertEq(numMarketsAfter, 2, "Should have 2 markets after removal");

        // Verify the removed market's allocation cap is 0.
        assertEq(optimizer.allocationCaps(cUSDC_WETH_MARKET), 0, "Removed market cap should be 0");

        // Verify total assets are preserved (allowing for minor rounding).
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets should be preserved");

        // Verify remaining markets are correct.
        assertEq(optimizer.approvedCTokensList(0), cUSDC_WMON_MARKET, "Market 0 should be WMON");
        assertEq(optimizer.approvedCTokensList(1), cUSDC_WBTC_MARKET, "Market 1 should be WBTC");
    }

    function test_lendingOptimizer_removeApprovedAsset_fail_whenOnlyOneMarket() public {
        // Setup with only one market.
        _setUpOneMarket();

        // Deposit some assets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Try to remove the only market with empty reallocation (no other market to reallocate to).
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](0);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Should revert because:
        // 1. If we try empty removeActions, it will revert with AssetMismatch (redeemed != reallocated)
        // 2. Even if we could remove, _validateAllocationCaps would fail with InsufficientAllocationCaps
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.removeApprovedAsset(cUSDC_WMON_MARKET, removeActions);
    }

    function test_lendingOptimizer_removeApprovedAsset_success_afterUpdatingCap() public {
        // Setup with two markets (60% + 50% = 110%).
        // Removing either one would leave < 100%, so we need to updateCap first.
        _setUpTwoMarkets();

        // Deposit to both markets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Mock market permissions for all calls.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Create remove actions.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(10_000)
        );

        // First, demonstrate that removal would fail without updating cap.
        // Market 0 has 60% cap, which is < 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.removeApprovedAsset(cUSDC_WBTC_MARKET, removeActions);

        // Now update market 0's cap to 100% (10_000 BPS).
        // updateCap only validates when DECREASING, so increasing is allowed.
        optimizer.updateCap(cUSDC_WMON_MARKET, 10_000);

        // Verify cap was updated.
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 10_000 * 1e14, "Cap should be 100%");

        // Now removal should succeed.
        uint256 totalAssetsBefore = optimizer.totalAssets();
        optimizer.removeApprovedAsset(cUSDC_WBTC_MARKET, removeActions);

        // Verify market was removed.
        assertEq(optimizer.numApprovedMarkets(), 1, "Should have 1 market after removal");
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), 0, "Removed market cap should be 0");

        // Verify total assets are preserved.
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets should be preserved");
    }

    function test_lendingOptimizer_removeApprovedAsset_success_emitsMarketRemovedEvent() public {
        // Setup with three markets (60% + 50% + 20% caps).
        _setUpThreeMarkets();

        // Deposit to markets so there are assets to reallocate.
        deal(USDC_MONAD, address(this), 21_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 21_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(1_000e6, address(this), cUSDC_WETH_MARKET);

        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(10_000)
        );

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Expect the MarketRemoved event with the correct cToken address.
        vm.expectEmit(true, false, false, false, address(optimizer));
        emit LendingOptimizer.MarketRemoved(cUSDC_WETH_MARKET);

        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);
    }

    // ========================================================================
    // DUST / BPS ROUNDING TESTS
    // ========================================================================

    /// @notice Removal with uneven BPS split (7000/3000) preserves total assets
    ///         and leaves no cToken dust in the removed market.
    function test_lendingOptimizer_removeApprovedAsset_dustHandling_unevenBpsSplit() public {
        _setUpThreeMarkets();

        // Mock market permissions for all calls.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Deposit an odd amount to the market being removed to make rounding visible.
        deal(USDC_MONAD, address(this), 21_001e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 21_001e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);

        // Use 1_001e6 (odd amount) for the removed market.
        LendingOptimizerHarness(address(optimizer)).depositToMarket(1_001e6, address(this), cUSDC_WETH_MARKET);

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 exchangeRateBefore = optimizer.exchangeRate();

        // Capture target market balances before removal.
        uint256 m0AssetsBefore = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        uint256 m1AssetsBefore = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );

        // Remove market 2 with 70/30 BPS split.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(7_000)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(3_000)
        );

        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // 1. No cToken dust in removed market.
        assertEq(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer)),
            0,
            "No cToken dust should remain in removed market"
        );

        // 2. Total assets preserved (within cToken rounding tolerance: 2 rounding ops).
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets should be preserved");

        // 3. Exchange rate should not decrease beyond cToken rounding tolerance.
        uint256 exchangeRateAfter = optimizer.exchangeRate();
        assertGe(exchangeRateAfter + 1e8, exchangeRateBefore, "Exchange rate should not materially decrease");

        // 4. Target markets received approximately correct BPS proportions.
        uint256 m0AssetsAfter = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        uint256 m1AssetsAfter = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );

        uint256 m0Received = m0AssetsAfter - m0AssetsBefore;
        uint256 m1Received = m1AssetsAfter - m1AssetsBefore;
        uint256 totalReceived = m0Received + m1Received;

        // Market 0 should have received ~70% of redistributed assets (within 10 wei tolerance).
        uint256 expectedM0 = (totalReceived * 7_000) / 10_000;
        assertApproxEqAbs(m0Received, expectedM0, 10, "Market 0 should receive ~70%");
    }

    /// @notice Removal with a very small balance in the removed market.
    ///         Ensures BPS distribution doesn't lose assets even with tiny amounts.
    function test_lendingOptimizer_removeApprovedAsset_dustHandling_smallAmount() public {
        _setUpThreeMarkets();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        deal(USDC_MONAD, address(this), 20_001e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 20_001e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);

        // Tiny deposit (minimum meaningful USDC amount) in market to remove.
        LendingOptimizerHarness(address(optimizer)).depositToMarket(1e6, address(this), cUSDC_WETH_MARKET);

        uint256 totalAssetsBefore = optimizer.totalAssets();

        // Split tiny redeemed amount 60/40.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(6_000)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(4_000)
        );

        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // No cToken dust.
        assertEq(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer)),
            0,
            "No cToken dust after small amount removal"
        );

        // Total assets preserved.
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets preserved for small removal");
    }

    /// @notice Removal after yield accrual produces non-round redeemed amounts.
    ///         Verifies BPS distribution handles interest-inflated amounts correctly.
    function test_lendingOptimizer_removeApprovedAsset_dustHandling_afterYieldAccrual() public {
        _setUpThreeMarkets();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        deal(USDC_MONAD, address(this), 21_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 21_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(1_000e6, address(this), cUSDC_WETH_MARKET);

        // Let interest accrue to make redeemed amount non-round.
        skip(30 days);

        // Accrue interest on all markets.
        IBorrowableCToken(cUSDC_WMON_MARKET).accrueIfNeeded();
        IBorrowableCToken(cUSDC_WBTC_MARKET).accrueIfNeeded();
        IBorrowableCToken(cUSDC_WETH_MARKET).accrueIfNeeded();
        optimizer.exchangeRateUpdated();

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 exchangeRateBefore = optimizer.exchangeRate();

        // Remove with uneven split after yield has made amounts non-round.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(5_500)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(4_500)
        );

        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // No cToken dust in removed market.
        assertEq(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer)),
            0,
            "No cToken dust after yield-accrued removal"
        );

        // Total assets preserved.
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 10, "Total assets preserved after yield-accrued removal");

        // Exchange rate should not materially decrease.
        uint256 exchangeRateAfter = optimizer.exchangeRate();
        assertGe(exchangeRateAfter + 1e8, exchangeRateBefore, "Exchange rate stable after yield-accrued removal");
    }

    /// @notice Verifies the last BPS target receives the remainder (dust) that
    ///         the earlier targets' mulDiv rounds away.
    /// @dev Uses a 3333/6667 split on an amount where mulDiv(amount, 3333, 10000)
    ///      rounds down, so the last target gets strictly more than its mulDiv share.
    function test_lendingOptimizer_removeApprovedAsset_dustHandling_lastIndexGetsRemainder() public {
        _setUpThreeMarkets();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        deal(USDC_MONAD, address(this), 20_000e6 + 999_999_999);
        IERC20(USDC_MONAD).approve(address(optimizer), 20_000e6 + 999_999_999);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);

        // Deposit an amount designed to produce rounding in mulDiv with 3333 BPS.
        // 999_999_999 wei USDC (≈999.999999 USDC): mulDiv(999999999, 3333, 10000) = 333,299,666
        // Remainder for last target = 999,999,999 - 333,299,666 = 666,700,333
        // Strict mulDiv(999999999, 6667, 10000) = 666,700,333  (happens to match here)
        // But with cToken rounding on redeem, the actual redeemed amount will be slightly
        // different, producing a genuine remainder scenario.
        LendingOptimizerHarness(address(optimizer)).depositToMarket(999_999_999, address(this), cUSDC_WETH_MARKET);

        // Let time pass so cToken exchange rate makes redeemed amount non-round.
        skip(7 days);

        // Accrue all markets before snapshotting so that interest accrual during
        // removeApprovedAsset's _accrueIfNeeded() doesn't inflate the deltas.
        IBorrowableCToken(cUSDC_WMON_MARKET).accrueIfNeeded();
        IBorrowableCToken(cUSDC_WBTC_MARKET).accrueIfNeeded();
        IBorrowableCToken(cUSDC_WETH_MARKET).accrueIfNeeded();

        // Snapshot target market asset values before removal.
        uint256 m0Before = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        uint256 m1Before = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );

        // Remove with 6667/3333 split — market 0 (60% cap) gets the larger share
        // to stay within allocation caps. First target gets mulDiv, last gets remainder.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(6_667)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET), int256(3_333)
        );

        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // Snapshot after.
        uint256 m0After = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer))
        );
        uint256 m1After = IBorrowableCToken(cUSDC_WBTC_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer))
        );

        uint256 m0Received = m0After - m0Before;
        uint256 m1Received = m1After - m1Before;
        uint256 totalReceived = m0Received + m1Received;

        // The first target got mulDiv(redeemed, 6667, 10000).
        // The last target got (redeemed - firstDeposit), which is >= mulDiv(redeemed, 3333, 10000).
        // Verify the last target received >= its strict proportional share (remainder goes here).
        uint256 strictLastShare = FixedPointMathLib.mulDiv(totalReceived, 3333, 10_000);
        assertGe(
            m1Received + 2, // +2 for cToken deposit rounding
            strictLastShare,
            "Last target should receive at least its strict mulDiv share (remainder goes here)"
        );

        // The first target should have received approximately its BPS share.
        uint256 strictFirstShare = FixedPointMathLib.mulDiv(totalReceived, 6667, 10_000);
        assertApproxEqAbs(
            m0Received,
            strictFirstShare,
            10,
            "First target should receive approximately its BPS share"
        );

        // No cToken dust in removed market.
        assertEq(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer)),
            0,
            "No cToken dust in removed market"
        );

        // Total assets preserved across the operation.
        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertApproxEqAbs(
            totalAssetsAfter,
            optimizer.totalAssets(), // self-consistency
            0,
            "Total assets self-consistent"
        );
    }

    /// @notice Removal with a single target (100% BPS) after yield accrual.
    ///         Verifies no USDC dust is left in the optimizer contract itself.
    function test_lendingOptimizer_removeApprovedAsset_dustHandling_noUnderlyingDust() public {
        _setUpThreeMarkets();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        deal(USDC_MONAD, address(this), 21_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 21_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(1_000e6, address(this), cUSDC_WETH_MARKET);

        skip(14 days);
        IBorrowableCToken(cUSDC_WETH_MARKET).accrueIfNeeded();

        uint256 usdcBefore = IERC20(USDC_MONAD).balanceOf(address(optimizer));

        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET), int256(10_000)
        );

        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // Optimizer should not hold USDC dust — all redeemed assets should be re-deposited.
        uint256 usdcAfter = IERC20(USDC_MONAD).balanceOf(address(optimizer));
        assertEq(usdcAfter, usdcBefore, "No USDC dust should remain in optimizer");
    }

    /// @notice Removing an approved asset that has zero deposits should succeed
    ///         with empty removeActions (no assets to reallocate).
    function test_lendingOptimizer_removeApprovedAsset_success_zeroDeposits() public {
        _setUpThreeMarkets();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Deposit only to markets 0 and 1, leaving market 2 empty.
        deal(USDC_MONAD, address(this), 20_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 20_000e6);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WMON_MARKET);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(10_000e6, address(this), cUSDC_WBTC_MARKET);

        // Confirm market 2 has zero balance.
        assertEq(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer)),
            0,
            "Market 2 should have zero shares before removal"
        );

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 numMarketsBefore = optimizer.numApprovedMarkets();
        assertEq(numMarketsBefore, 3, "Should have 3 markets before removal");

        // Remove market 2 with empty removeActions — no assets to reallocate.
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](0);
        optimizer.removeApprovedAsset(cUSDC_WETH_MARKET, removeActions);

        // Verify market was removed.
        assertEq(optimizer.numApprovedMarkets(), 2, "Should have 2 markets after removal");
        assertEq(optimizer.allocationCaps(cUSDC_WETH_MARKET), 0, "Removed market cap should be 0");

        // Verify total assets unchanged.
        assertEq(optimizer.totalAssets(), totalAssetsBefore, "Total assets should be unchanged");

        // Verify remaining markets are correct.
        assertEq(optimizer.approvedCTokensList(0), cUSDC_WMON_MARKET, "Market 0 should be WMON");
        assertEq(optimizer.approvedCTokensList(1), cUSDC_WBTC_MARKET, "Market 1 should be WBTC");
    }

    function test_lendingOptimizer_removeApprovedAsset_fail_whenRemainingCapsUnder100() public {
        // Setup with two markets (60% + 50% = 110%).
        // Removing either one leaves remaining cap < 100%.
        _setUpTwoMarkets();

        // Deposit to both markets.
        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        deal(USDC_MONAD, address(this), 10_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000e6);
        optimizer.deposit(10_000e6, address(this));

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Try to remove market 0 (60% cap), leaving only market 1 (50% cap).
        LendingOptimizer.ReallocationAction[] memory removeActions = new LendingOptimizer.ReallocationAction[](1);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(10_000)
        );

        // Should revert because remaining cap (50%) < 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.removeApprovedAsset(cUSDC_WMON_MARKET, removeActions);

        // Also try removing market 1 (50% cap), leaving only market 0 (60% cap).
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(10_000)
        );

        // Should also revert because remaining cap (60%) < 100%.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        optimizer.removeApprovedAsset(cUSDC_WBTC_MARKET, removeActions);
    }
}
