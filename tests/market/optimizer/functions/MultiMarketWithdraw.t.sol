// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Multi-Market Withdrawal Tests
/// @notice Tests ERC4626 standard withdraw/redeem across multiple markets.
contract TestMultiMarketWithdraw is TestBaseLendingOptimizer {

    event Withdraw(
        address indexed by,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();
    }

    function _depositForUser(address user, uint256 amount) internal {
        deal(USDC_MONAD, user, amount, true);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(optimizer), amount);
        optimizer.deposit(amount, user);
        vm.stopPrank();
    }

    function _depositToMarket(address user, uint256 amount, address market) internal {
        deal(USDC_MONAD, user, amount, true);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(optimizer), amount);
        optimizer.deposit(amount, user, market);
        vm.stopPrank();
    }

    // ============ Single Market Full Withdraw ============

    /// @notice All assets in one market, standard withdraw drains it.
    function test_multiMarketWithdraw_singleMarketFullWithdraw() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 maxAssets = optimizer.maxWithdraw(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(maxAssets, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + maxAssets,
            "Should receive exact assets"
        );

        vm.stopPrank();
    }

    // ============ Two Market Partial Withdraw ============

    /// @notice Assets split across 2 markets, withdraw enough to need both.
    function test_multiMarketWithdraw_twoMarketPartialWithdraw() public {
        // Deposit to two markets.
        _depositToMarket(user1, 10_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 10_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        // Withdraw more than any single market holds — forces multi-market.
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(maxAssets, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + maxAssets,
            "Should receive exact assets"
        );

        vm.stopPrank();
    }

    // ============ Three Market Full Withdraw ============

    /// @notice `withdraw(maxWithdraw(owner))` drains all 3 markets.
    function test_multiMarketWithdraw_threeMarketFullWithdraw() public {
        _depositToMarket(user1, 10_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 10_000e6, cUSDC_WBTC_MARKET);
        _depositToMarket(user1, 10_000e6, cUSDC_WETH_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 maxAssets = optimizer.maxWithdraw(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(maxAssets, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + maxAssets,
            "Should receive exact assets"
        );

        vm.stopPrank();
    }

    // ============ Worst-Yield-First Ordering ============

    /// @notice Verify lowest-rate market is drained before higher-rate.
    function test_multiMarketWithdraw_worstYieldFirst() public {
        // Deposit to two markets with different utilization (different rates).
        // cUSDC_WMON_MARKET has lower utilization (lower rate).
        // cUSDC_WBTC_MARKET has higher utilization (higher rate).
        _depositToMarket(user1, 50_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 50_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        // Get rates to determine which is lower.
        IBorrowableCToken wmonCToken = IBorrowableCToken(cUSDC_WMON_MARKET);
        IBorrowableCToken wbtcCToken = IBorrowableCToken(cUSDC_WBTC_MARKET);

        uint256 wmonRate = wmonCToken.IRM().supplyRate(
            wmonCToken.assetsHeld(),
            wmonCToken.marketOutstandingDebt(),
            wmonCToken.interestFee()
        );
        uint256 wbtcRate = wbtcCToken.IRM().supplyRate(
            wbtcCToken.assetsHeld(),
            wbtcCToken.marketOutstandingDebt(),
            wbtcCToken.interestFee()
        );

        // Identify which market has the lower rate (worst yield).
        address worstMarket = wmonRate < wbtcRate ? cUSDC_WMON_MARKET : cUSDC_WBTC_MARKET;
        address betterMarket = wmonRate < wbtcRate ? cUSDC_WBTC_MARKET : cUSDC_WMON_MARKET;

        uint256 worstBalBefore = IBorrowableCToken(worstMarket).balanceOf(address(optimizer));
        uint256 betterBalBefore = IBorrowableCToken(betterMarket).balanceOf(address(optimizer));

        // Withdraw a small amount — should come from worst-yield market first.
        optimizer.withdraw(10_000e6, user1, user1);

        uint256 worstBalAfter = IBorrowableCToken(worstMarket).balanceOf(address(optimizer));
        uint256 betterBalAfter = IBorrowableCToken(betterMarket).balanceOf(address(optimizer));

        // Worst-yield market should have decreased.
        assertLt(worstBalAfter, worstBalBefore, "Worst-yield market should be drained first");
        // Better-yield market should be untouched (withdrawal fits in worst market).
        assertEq(betterBalAfter, betterBalBefore, "Better-yield market should be untouched");

        vm.stopPrank();
    }

    // ============ maxWithdraw Reflects Liquidity ============

    /// @notice When market liquidity is limited, maxWithdraw is reduced.
    function test_multiMarketWithdraw_maxWithdrawReflectsLiquidity() public {
        // Deposit a large amount to the optimizer.
        _depositToMarket(user1, 100_000e6, cUSDC_WMON_MARKET);

        optimizer.accrueIfNeeded();

        uint256 maxBefore = optimizer.maxWithdraw(user1);
        uint256 ownerAssets = optimizer.convertToAssets(optimizer.balanceOf(user1));

        // maxWithdraw should be <= owner's asset value.
        assertLe(maxBefore, ownerAssets, "maxWithdraw should not exceed owner assets");

        // maxWithdraw should be > 0 since there is liquidity.
        assertGt(maxBefore, 0, "maxWithdraw should be > 0 with available liquidity");
    }

    // ============ maxRedeem Reflects Liquidity ============

    /// @notice maxRedeem caps by available liquidity in share terms.
    function test_multiMarketWithdraw_maxRedeemReflectsLiquidity() public {
        _depositToMarket(user1, 100_000e6, cUSDC_WMON_MARKET);

        optimizer.accrueIfNeeded();

        uint256 maxShares = optimizer.maxRedeem(user1);
        uint256 ownerShares = optimizer.balanceOf(user1);

        // maxRedeem should be <= owner's shares.
        assertLe(maxShares, ownerShares, "maxRedeem should not exceed owner shares");

        // maxRedeem should be > 0.
        assertGt(maxShares, 0, "maxRedeem should be > 0 with available liquidity");
    }

    // ============ Redeem Multi-Market ============

    /// @notice Standard `redeem(maxRedeem(owner))` succeeds across markets.
    function test_multiMarketWithdraw_redeemMultiMarket() public {
        _depositToMarket(user1, 10_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 10_000e6, cUSDC_WBTC_MARKET);
        _depositToMarket(user1, 10_000e6, cUSDC_WETH_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 maxShares = optimizer.maxRedeem(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 assets = optimizer.redeem(maxShares, user1, user1);

        assertGt(assets, 0, "Should receive assets");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + assets,
            "Balance should increase by redeemed assets"
        );

        vm.stopPrank();
    }

    // ============ Partial Liquidity Withdraw ============

    /// @notice One market has limited idle cash, withdraw pulls remainder from another.
    function test_multiMarketWithdraw_partialLiquidity() public {
        // Deposit to two markets.
        _depositToMarket(user1, 30_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 30_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        // Both markets have existing borrows (from setUp), so idle cash < total deposits.
        // A full withdraw should span both markets if needed.
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(maxAssets, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + maxAssets,
            "Should receive exact assets"
        );

        vm.stopPrank();
    }

    // ============ Paused Market Skipped ============

    /// @notice Paused market's liquidity is excluded from maxWithdraw and withdrawal loop.
    function test_multiMarketWithdraw_pausedMarketSkipped() public {
        _depositToMarket(user1, 10_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 10_000e6, cUSDC_WBTC_MARKET);

        optimizer.accrueIfNeeded();

        uint256 maxBefore = optimizer.maxWithdraw(user1);

        // Pause redeem on the WMON market's MarketManager.
        MarketManagerIsolated mm = MarketManagerIsolated(
            address(IBorrowableCToken(cUSDC_WMON_MARKET).marketManager())
        );
        mm.setRedeemPaused(true);

        uint256 maxAfter = optimizer.maxWithdraw(user1);

        // maxWithdraw should decrease since one market is now excluded.
        assertLt(maxAfter, maxBefore, "maxWithdraw should decrease when market is paused");

        // Withdraw should still succeed using remaining unpaused market.
        vm.startPrank(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(maxAfter, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + maxAfter,
            "Should receive exact assets"
        );

        vm.stopPrank();
    }

    // ============ ERC4626 Invariant: withdraw(maxWithdraw(owner)) Never Reverts ============

    /// @notice Core ERC4626 invariant — the whole point of multi-market withdrawal.
    function test_multiMarketWithdraw_erc4626Invariant_neverReverts() public {
        // Spread assets across all three markets.
        _depositToMarket(user1, 20_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WBTC_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WETH_MARKET);

        // Let some time pass for interest to accrue.
        skip(7 days);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 maxAssets = optimizer.maxWithdraw(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        // This must not revert.
        uint256 shares = optimizer.withdraw(maxAssets, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + maxAssets,
            "Should receive exact assets"
        );

        vm.stopPrank();
    }

    /// @notice Core ERC4626 invariant for redeem — `redeem(maxRedeem(owner))` never reverts.
    function test_multiMarketWithdraw_erc4626Invariant_redeemNeverReverts() public {
        _depositToMarket(user1, 20_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WBTC_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WETH_MARKET);

        skip(7 days);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 maxShares = optimizer.maxRedeem(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        // This must not revert.
        uint256 assets = optimizer.redeem(maxShares, user1, user1);

        assertGt(assets, 0, "Should receive assets");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + assets,
            "Balance should match"
        );

        vm.stopPrank();
    }

    // ============ Targeted Withdraw Unchanged ============

    /// @notice `withdraw(assets, receiver, owner, targetMarket)` still uses single market.
    function test_multiMarketWithdraw_targetedWithdrawUnchanged() public {
        _depositToMarket(user1, 20_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);

        uint256 wmonBalBefore = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 wbtcBalBefore = IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer));

        // Targeted withdraw from WMON only.
        optimizer.withdraw(5_000e6, user1, user1, cUSDC_WMON_MARKET);

        uint256 wmonBalAfter = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 wbtcBalAfter = IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer));

        // WMON should decrease, WBTC untouched.
        assertLt(wmonBalAfter, wmonBalBefore, "Target market should decrease");
        assertEq(wbtcBalAfter, wbtcBalBefore, "Non-target market should be untouched");

        vm.stopPrank();
    }

    /// @notice `redeem(shares, receiver, owner, targetMarket)` still uses single market.
    function test_multiMarketWithdraw_targetedRedeemUnchanged() public {
        _depositToMarket(user1, 20_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);

        uint256 wmonBalBefore = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 wbtcBalBefore = IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer));

        // Targeted redeem from WMON only.
        optimizer.redeem(5_000e6, user1, user1, cUSDC_WMON_MARKET);

        uint256 wmonBalAfter = IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(optimizer));
        uint256 wbtcBalAfter = IBorrowableCToken(cUSDC_WBTC_MARKET).balanceOf(address(optimizer));

        assertLt(wmonBalAfter, wmonBalBefore, "Target market should decrease");
        assertEq(wbtcBalAfter, wbtcBalBefore, "Non-target market should be untouched");

        vm.stopPrank();
    }

    // ============ Exchange Rate Consistency ============

    /// @notice Exchange rate should not decrease from a multi-market withdrawal.
    function test_multiMarketWithdraw_exchangeRateConsistency() public {
        _depositToMarket(user1, 30_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 30_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);

        for (uint256 i; i < 5; ++i) {
            optimizer.accrueIfNeeded();
            uint256 rateBefore = optimizer.exchangeRate();

            uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 10;
            optimizer.withdraw(assetsToWithdraw, user1, user1);

            uint256 rateAfter = optimizer.exchangeRate();
            assertGe(rateAfter, rateBefore, "Exchange rate should not decrease from withdrawal");

            skip(1 days);
        }

        vm.stopPrank();
    }

    // ============ Total Assets Decreases Correctly ============

    /// @notice totalAssets should decrease by exactly the withdrawn amount.
    function test_multiMarketWithdraw_totalAssetsDecreasesCorrectly() public {
        _depositToMarket(user1, 20_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        optimizer.withdraw(assetsToWithdraw, user1, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();
        assertEq(
            totalAssetsBefore - totalAssetsAfter,
            assetsToWithdraw,
            "Total assets should decrease by exact withdrawn amount"
        );

        vm.stopPrank();
    }

    // ============ Fuzz Tests ============

    function testFuzz_multiMarketWithdraw_withdraw(uint256 assetsToWithdraw) public {
        _depositToMarket(user1, 50_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 50_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 maxAssets = optimizer.maxWithdraw(user1);
        assetsToWithdraw = bound(assetsToWithdraw, 1e6, maxAssets);

        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + assetsToWithdraw,
            "Should receive exact assets"
        );

        vm.stopPrank();
    }

    function testFuzz_multiMarketWithdraw_redeem(uint256 sharesToRedeem) public {
        _depositToMarket(user1, 50_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 50_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 maxShares = optimizer.maxRedeem(user1);
        sharesToRedeem = bound(sharesToRedeem, 1e6, maxShares);

        uint256 sharesBefore = optimizer.balanceOf(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1);

        assertGt(assets, 0, "Should receive assets");
        assertEq(
            optimizer.balanceOf(user1),
            sharesBefore - sharesToRedeem,
            "Should burn exact shares"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + assets,
            "Balance should increase by redeemed assets"
        );

        vm.stopPrank();
    }

    // ============ Allowance / Approval for Multi-Market ============

    /// @notice Standard ERC4626 withdraw with msg.sender != owner via allowance.
    function test_multiMarketWithdraw_withdrawWithAllowance() public {
        _depositToMarket(user1, 20_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WBTC_MARKET);

        optimizer.accrueIfNeeded();

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        // user1 approves user2 for the expected shares (+ buffer for rounding).
        vm.prank(user1);
        optimizer.approve(user2, expectedShares + 1);

        // user2 withdraws on behalf of user1, receives assets themselves.
        vm.startPrank(user2);
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user2, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user2),
            user2BalanceBefore + assetsToWithdraw,
            "Caller should receive exact assets"
        );

        vm.stopPrank();
    }

    /// @notice Standard ERC4626 redeem with msg.sender != owner via allowance.
    function test_multiMarketWithdraw_redeemWithAllowance() public {
        _depositToMarket(user1, 20_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WBTC_MARKET);

        optimizer.accrueIfNeeded();

        uint256 sharesToRedeem = optimizer.maxRedeem(user1) / 2;

        // user1 approves user2 for the shares.
        vm.prank(user1);
        optimizer.approve(user2, sharesToRedeem);

        // user2 redeems on behalf of user1.
        vm.startPrank(user2);
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        uint256 assets = optimizer.redeem(sharesToRedeem, user2, user1);

        assertGt(assets, 0, "Should receive assets");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user2),
            user2BalanceBefore + assets,
            "Caller should receive assets"
        );
        assertEq(optimizer.allowance(user1, user2), 0, "Allowance should be spent");

        vm.stopPrank();
    }

    // ============ Different Receiver ============

    /// @notice Withdraw to a different receiver via multi-market path.
    function test_multiMarketWithdraw_differentReceiver() public {
        _depositToMarket(user1, 20_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 20_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);
        optimizer.accrueIfNeeded();

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        optimizer.withdraw(assetsToWithdraw, user2, user1);

        assertEq(
            IERC20(USDC_MONAD).balanceOf(user2),
            user2BalanceBefore + assetsToWithdraw,
            "Receiver should get exact assets"
        );
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), 0, "Owner should not receive assets");

        vm.stopPrank();
    }

    // ============ Multiple Users Full Withdraw ============

    /// @notice Two users both deposited across markets, both do full maxWithdraw.
    function test_multiMarketWithdraw_multipleUsersFullWithdraw() public {
        _depositToMarket(user1, 15_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 15_000e6, cUSDC_WBTC_MARKET);
        _depositToMarket(user2, 10_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user2, 10_000e6, cUSDC_WETH_MARKET);

        // user1 withdraws everything.
        vm.startPrank(user1);
        optimizer.accrueIfNeeded();
        uint256 max1 = optimizer.maxWithdraw(user1);
        uint256 bal1Before = IERC20(USDC_MONAD).balanceOf(user1);
        optimizer.withdraw(max1, user1, user1);
        assertEq(optimizer.balanceOf(user1), 0, "User1 should have no shares");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), bal1Before + max1, "User1 should receive exact assets");
        vm.stopPrank();

        // user2 withdraws everything.
        vm.startPrank(user2);
        optimizer.accrueIfNeeded();
        uint256 max2 = optimizer.maxWithdraw(user2);
        uint256 bal2Before = IERC20(USDC_MONAD).balanceOf(user2);
        optimizer.withdraw(max2, user2, user2);
        assertEq(optimizer.balanceOf(user2), 0, "User2 should have no shares");
        assertEq(IERC20(USDC_MONAD).balanceOf(user2), bal2Before + max2, "User2 should receive exact assets");
        vm.stopPrank();
    }

    // ============ Zero Amount Reverts ============

    /// @notice withdraw(0) should revert.
    function test_multiMarketWithdraw_zeroWithdrawReverts() public {
        _depositToMarket(user1, 10_000e6, cUSDC_WMON_MARKET);

        vm.startPrank(user1);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.withdraw(0, user1, user1);
        vm.stopPrank();
    }

    /// @notice redeem(0) should revert (previewRedeem(0) = 0 assets).
    function test_multiMarketWithdraw_zeroRedeemReverts() public {
        _depositToMarket(user1, 10_000e6, cUSDC_WMON_MARKET);

        vm.startPrank(user1);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.redeem(0, user1, user1);
        vm.stopPrank();
    }

    // ============ All Markets Paused ============

    /// @notice If every market is paused, maxWithdraw returns 0 and withdraw reverts.
    function test_multiMarketWithdraw_allMarketsPaused() public {
        _depositToMarket(user1, 10_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 10_000e6, cUSDC_WBTC_MARKET);
        _depositToMarket(user1, 10_000e6, cUSDC_WETH_MARKET);

        // Pause redeem on all three market managers.
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];
        for (uint256 i; i < 3; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(
                address(IBorrowableCToken(markets[i]).marketManager())
            );
            mm.setRedeemPaused(true);
        }

        assertEq(optimizer.maxWithdraw(user1), 0, "maxWithdraw should be 0 when all paused");
        assertEq(optimizer.maxRedeem(user1), 0, "maxRedeem should be 0 when all paused");

        // Any non-zero withdraw should revert.
        vm.startPrank(user1);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientLiquidity.selector);
        optimizer.withdraw(1e6, user1, user1);
        vm.stopPrank();
    }

    // ============ Withdraw After Time Passes (Fee/Yield Interaction) ============

    /// @notice Interest accrues, fees vest, then multi-market withdraw succeeds.
    function test_multiMarketWithdraw_afterTimePassesWithFees() public {
        _depositToMarket(user1, 30_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 30_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);

        // First withdraw to establish baseline (triggers initial accrual/fee).
        uint256 smallWithdraw = optimizer.maxWithdraw(user1) / 10;
        optimizer.withdraw(smallWithdraw, user1, user1);
        uint256 rateAfterFirst = optimizer.exchangeRate();

        // Skip time — interest accrues in underlying markets.
        skip(7 days);

        // Trigger yield detection and fee extraction.
        optimizer.accrueIfNeeded();

        // Skip vesting period.
        skip(1 days);

        uint256 rateAfterYield = optimizer.exchangeRate();

        // Exchange rate should increase after yield vests.
        assertGe(rateAfterYield, rateAfterFirst, "Rate should not decrease after yield vests");

        // Full multi-market withdraw should still work.
        // Accrue first so maxWithdraw uses a fresh exchange rate.
        optimizer.accrueIfNeeded();
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(maxAssets, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            balanceBefore + maxAssets,
            "Should receive exact assets"
        );

        vm.stopPrank();
    }
}
