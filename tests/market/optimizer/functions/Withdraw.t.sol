// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestLendingOptimizerWithdraw is TestBaseLendingOptimizer {

    event Withdraw(
        address indexed by,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public override {
        super.setUp();

        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WETH_MARKET;
        approvedCTokens[2] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 5_000;
        allocationCapsBps[1] = 4_000;
        allocationCapsBps[2] = 1_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        deal(USDC_MONAD, address(this), 77777, true);

        IERC20(USDC_MONAD).approve(address(optimizer), 77777);

        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(0);
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

    // ============ withdraw(assets, receiver, owner, targetMarket) Tests ============

    function test_lendingOptimizer_withdraw_success_targetMarket() public {
        // Deposit first
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        uint256 sharesBefore = optimizer.balanceOf(user1);
        uint256 assetsBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1, cUSDC_WMON_MARKET);

        assertGt(shares, 0, "Should burn shares");
        assertEq(optimizer.balanceOf(user1), sharesBefore - shares, "Shares should be burned");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), assetsBefore + assetsToWithdraw, "User should receive exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_targetMarketDifferentReceiver() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        // Withdraw with user2 as receiver
        optimizer.withdraw(assetsToWithdraw, user2, user1, cUSDC_WMON_MARKET);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assetsToWithdraw, "Receiver should get exact assets");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), 0, "Owner should not receive assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_targetMarketAllMarkets() public {
        // Deposit to each market
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WETH_MARKET, cUSDC_WBTC_MARKET];
        uint256 depositAmount = 10_000e6;

        for (uint256 i = 0; i < markets.length; i++) {
            _depositToMarket(user1, depositAmount, markets[i]);
        }

        vm.startPrank(user1);

        // Withdraw from each market
        for (uint256 i = 0; i < markets.length; i++) {
            uint256 assetsToWithdraw = 1000e6;
            uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

            uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1, markets[i]);

            assertGt(shares, 0, "Should burn shares");
            assertEq(
                IERC20(USDC_MONAD).balanceOf(user1),
                balanceBefore + assetsToWithdraw,
                "Should receive exact assets"
            );
        }

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_targetMarketEmitsEvent() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // Accrue first so preview matches actual
        optimizer.accrueIfNeeded();
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(user1, user1, user1, assetsToWithdraw, expectedShares);

        optimizer.withdraw(assetsToWithdraw, user1, user1, cUSDC_WMON_MARKET);

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_fail_targetMarketNotApproved() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;
        address fakeMarket = makeAddr("fakeMarket");

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.withdraw(assetsToWithdraw, user1, user1, fakeMarket);

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_targetMarketWithAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // Accrue first and calculate shares after accrual
        optimizer.accrueIfNeeded();
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        // User1 approves user2 for expected shares (add buffer for any rounding)
        vm.prank(user1);
        optimizer.approve(user2, expectedShares + 1);

        // User2 withdraws on behalf of user1
        vm.startPrank(user2);

        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user2, user1, cUSDC_WMON_MARKET);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assetsToWithdraw, "Caller should receive assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_fail_targetMarketInsufficientAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        // User1 approves less than needed
        vm.prank(user1);
        optimizer.approve(user2, expectedShares / 2);

        // User2 tries to withdraw more than allowed
        vm.startPrank(user2);

        vm.expectRevert();
        optimizer.withdraw(assetsToWithdraw, user2, user1, cUSDC_WMON_MARKET);

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_targetMarketMultipleWithdraws() public {
        uint256 depositAmount = 50_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 numWithdraws = 5;

        for (uint256 i = 0; i < numWithdraws; i++) {
            // Use maxWithdraw / 10 to ensure we can do multiple withdraws
            uint256 withdrawAmount = optimizer.maxWithdraw(user1) / 10;
            uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
            uint256 sharesBefore = optimizer.balanceOf(user1);

            uint256 shares = optimizer.withdraw(withdrawAmount, user1, user1, cUSDC_WMON_MARKET);

            assertGt(shares, 0, "Should burn shares");
            assertLt(optimizer.balanceOf(user1), sharesBefore, "Shares should decrease");
            assertEq(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore + withdrawAmount, "Should receive exact assets");
        }

        vm.stopPrank();
    }

    // ============ withdraw(assets, receiver, owner) - ERC4626 Standard Tests ============

    function test_lendingOptimizer_withdraw_success_optimalMarket() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        uint256 sharesBefore = optimizer.balanceOf(user1);
        uint256 assetsBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(optimizer.balanceOf(user1), sharesBefore - shares, "Shares should be burned");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), assetsBefore + assetsToWithdraw, "User should receive exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_optimalMarketDifferentReceiver() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        optimizer.withdraw(assetsToWithdraw, user2, user1);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assetsToWithdraw, "Receiver should get exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_optimalMarketEmitsEvent() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // Accrue first so preview matches actual
        optimizer.accrueIfNeeded();
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(user1, user1, user1, assetsToWithdraw, expectedShares);

        optimizer.withdraw(assetsToWithdraw, user1, user1);

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_optimalMarketSelectsCorrectly() public {
        // Deposit to multiple markets
        _depositToMarket(user1, 50_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 30_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = 10_000e6;

        // Get the expected optimal target before withdraw
        uint256 expectedTarget = optimizer.optimalWithdrawalTarget(assetsToWithdraw);
        address expectedMarket = optimizer.approvedCTokensList(expectedTarget);

        // Get market balance before
        uint256 marketBalanceBefore = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));

        optimizer.withdraw(assetsToWithdraw, user1, user1);

        // Verify withdraw came from the expected market
        uint256 marketBalanceAfter = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));
        assertLt(marketBalanceAfter, marketBalanceBefore, "Expected market should have reduced balance");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_optimalMarketMultipleWithdraws() public {
        uint256 depositAmount = 100_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 numWithdraws = 5;

        for (uint256 i = 0; i < numWithdraws; i++) {
            // Use maxWithdraw / 10 to ensure we can do multiple withdraws
            uint256 withdrawAmount = optimizer.maxWithdraw(user1) / 10;
            uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
            uint256 sharesBefore = optimizer.balanceOf(user1);

            uint256 shares = optimizer.withdraw(withdrawAmount, user1, user1);

            assertGt(shares, 0, "Should burn shares");
            assertLt(optimizer.balanceOf(user1), sharesBefore, "Shares should decrease");
            assertEq(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore + withdrawAmount, "Should receive exact assets");
        }

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_smallAmount() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Withdraw small amount
        uint256 assetsToWithdraw = 1e6;
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertGt(shares, 0, "Should burn shares even for small withdraw");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore + assetsToWithdraw, "Should receive exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_largeAmount() public {
        uint256 depositAmount = 1_000_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Accrue first so maxWithdraw is accurate
        optimizer.accrueIfNeeded();

        // Withdraw most assets (leave some buffer for rounding)
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        uint256 assetsToWithdraw = maxAssets - 1000e6;

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertGt(shares, 0, "Large withdraw should burn shares");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), assetsToWithdraw, "Should receive exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_multipleUsersWithdraw() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);
        _depositForUser(user2, depositAmount);

        // Use maxWithdraw to account for cToken rounding
        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // User1 withdraws
        vm.startPrank(user1);
        uint256 user1BalanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
        uint256 shares1 = optimizer.withdraw(assetsToWithdraw, user1, user1);
        vm.stopPrank();

        // User2 withdraws
        vm.startPrank(user2);
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);
        uint256 shares2 = optimizer.withdraw(assetsToWithdraw, user2, user2);
        vm.stopPrank();

        assertGt(shares1, 0, "User1 should burn shares");
        assertGt(shares2, 0, "User2 should burn shares");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), user1BalanceBefore + assetsToWithdraw, "User1 should receive exact assets");
        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assetsToWithdraw, "User2 should receive exact assets");
    }

    function test_lendingOptimizer_withdraw_success_afterTimePasses() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Use maxWithdraw to account for cToken rounding
        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 10;

        // First withdraw (this triggers accrueIfNeeded which may extract fees)
        uint256 shares1 = optimizer.withdraw(assetsToWithdraw, user1, user1);

        // Record exchange rate AFTER first withdraw (after initial fee extraction)
        uint256 rateAfterFirstWithdraw = optimizer.exchangeRate();

        // Skip time (interest accrues in underlying markets)
        skip(7 days);

        // Trigger yield detection and start vesting
        optimizer.accrueIfNeeded();

        // Skip vesting period to let yield vest
        skip(1 days);

        // Record exchange rate after yield vests
        uint256 rateAfterYieldVests = optimizer.exchangeRate();

        // Second withdraw
        uint256 shares2 = optimizer.withdraw(assetsToWithdraw, user1, user1);

        // Both withdraws should burn shares
        assertGt(shares1, 0, "First withdraw should burn shares");
        assertGt(shares2, 0, "Second withdraw should burn shares");

        // Exchange rate should increase or stay same after yield vests (comparing post-fee states).
        // Fee extraction happens during accrueIfNeeded, which dilutes the rate. But between
        // fee extractions, yield should increase the rate.
        assertGe(rateAfterYieldVests, rateAfterFirstWithdraw, "Exchange rate should not decrease between accruals");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_previewMatchesActual() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // Accrue first so preview matches actual
        optimizer.accrueIfNeeded();
        uint256 previewedShares = optimizer.previewWithdraw(assetsToWithdraw);

        uint256 actualShares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        // Per ERC4626, actual should be >= preview (may burn slightly more due to rounding)
        assertGe(actualShares, previewedShares, "Actual shares should be >= previewed shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_exchangeRateConsistency() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // Accrue first to get stable state
        optimizer.accrueIfNeeded();

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();
        uint256 totalSupplyAfter = optimizer.totalSupply();

        // Verify supply decreased by shares burned
        assertEq(totalSupplyAfter, totalSupplyBefore - shares, "Supply should decrease by burned shares");

        // Verify assets decreased by exact withdrawn amount
        assertEq(totalAssetsAfter, totalAssetsBefore - assetsToWithdraw, "Assets should decrease by exact withdrawn amount");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_fullWithdraw() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Accrue first so maxWithdraw is accurate after internal accrual
        optimizer.accrueIfNeeded();
        uint256 maxAssets = optimizer.maxWithdraw(user1);

        uint256 shares = optimizer.withdraw(maxAssets, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_fail_insufficientBalance() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 tooManyAssets = optimizer.maxWithdraw(user1) + 1000e6;

        vm.expectRevert();
        optimizer.withdraw(tooManyAssets, user1, user1);

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_withAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // Accrue first so preview matches actual
        optimizer.accrueIfNeeded();
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        // User1 approves user2 (add buffer for any rounding)
        vm.prank(user1);
        optimizer.approve(user2, expectedShares + 1);

        // User2 withdraws on behalf of user1
        vm.startPrank(user2);

        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        optimizer.withdraw(assetsToWithdraw, user2, user1);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assetsToWithdraw, "Caller should receive assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_withInfiniteAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // User1 approves max uint256
        vm.prank(user1);
        optimizer.approve(user2, type(uint256).max);

        // User2 withdraws on behalf of user1
        vm.startPrank(user2);

        optimizer.withdraw(assetsToWithdraw, user2, user1);

        // Allowance should remain max (infinite approval)
        assertEq(optimizer.allowance(user1, user2), type(uint256).max, "Infinite allowance should persist");

        vm.stopPrank();
    }

    // ============ Withdraw vs Redeem Equivalence Tests ============

    function test_lendingOptimizer_withdraw_redeemEquivalence() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        // Accrue first to get stable state
        optimizer.accrueIfNeeded();

        // Use maxWithdraw to account for cToken rounding
        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 10;

        // Get expected shares for withdrawing assets
        uint256 sharesForWithdraw = optimizer.previewWithdraw(assetsToWithdraw);

        // Get expected assets for redeeming those shares
        uint256 assetsForRedeem = optimizer.previewRedeem(sharesForWithdraw);

        // Withdraw and redeem should be near-inverse operations within small rounding tolerance.
        // Note: Due to rounding directions (previewWithdraw rounds UP, previewRedeem rounds DOWN),
        // the relationship can vary slightly depending on exchange rate and amounts.
        assertApproxEqRel(assetsToWithdraw, assetsForRedeem, 0.0001e18, "Withdraw and redeem should be near-inverse operations");
    }

    // ============ Invariant Tests ============

    function test_lendingOptimizer_withdraw_invariant_exactAssetsReceived() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Use maxWithdraw to account for cToken rounding
        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
        optimizer.withdraw(assetsToWithdraw, user1, user1);
        uint256 balanceAfter = IERC20(USDC_MONAD).balanceOf(user1);

        // Withdraw should always return exact assets requested
        assertEq(balanceAfter - balanceBefore, assetsToWithdraw, "Must receive exact assets requested");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_invariant_sharesMatchFormula() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Use maxWithdraw to account for cToken rounding
        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        // Accrue first to get post-accrual state
        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);
        uint256 actualShares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        // Verify the ERC4626 formula: shares = assets * totalSupply / totalAssets (round up)
        uint256 calculatedShares = (assetsToWithdraw * totalSupplyBefore + totalAssetsBefore - 1) / totalAssetsBefore;

        // Allow for small rounding difference
        uint256 diff = actualShares > calculatedShares
            ? actualShares - calculatedShares
            : calculatedShares - actualShares;

        assertLe(diff, 1, "Shares should match formula calculation");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_invariant_exchangeRateNeverDecreases() public {
        uint256 depositAmount = 50_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Test that individual withdraw operations don't decrease exchange rate.
        // Note: Fee extraction (which happens during accrueIfNeeded) will decrease
        // the exchange rate as fees are taken from yield. This test focuses on
        // ensuring withdrawals themselves maintain the rate.
        for (uint256 i = 0; i < 5; i++) {
            // Accrue first to settle any pending yield/fees
            optimizer.accrueIfNeeded();

            // Record rate immediately before withdraw
            uint256 rateBefore = optimizer.exchangeRate();

            // Use maxWithdraw / 10 to ensure we can do multiple withdraws
            uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 10;

            optimizer.withdraw(assetsToWithdraw, user1, user1);

            // Record rate immediately after withdraw
            uint256 rateAfter = optimizer.exchangeRate();

            // Exchange rate should not decrease from a withdraw operation itself.
            // The ratio of assets-to-shares should remain constant or increase.
            assertGe(rateAfter, rateBefore, "Exchange rate should not decrease from withdrawal");

            // Skip time to generate yield for next iteration
            skip(1 days);
        }

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_invariant_totalAssetsDecreasesCorrectly() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Use maxWithdraw to account for cToken rounding
        uint256 assetsToWithdraw = optimizer.maxWithdraw(user1) / 2;

        uint256 totalAssetsBefore = optimizer.totalAssets();

        optimizer.withdraw(assetsToWithdraw, user1, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();

        // Total assets should decrease by exactly the amount withdrawn
        // Allow for 1 wei difference due to interest accrual in underlying markets.
        assertApproxEqAbs(totalAssetsBefore - totalAssetsAfter, assetsToWithdraw, 1, "Total assets should decrease by exact withdrawn amount");

        vm.stopPrank();
    }

    // ============ Fuzz Tests ============

    function testFuzz_lendingOptimizer_withdraw_targetMarket(uint256 assetsToWithdraw) public {
        uint256 depositAmount = 100_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        // Accrue first so maxWithdraw is accurate
        optimizer.accrueIfNeeded();

        // Bound to reasonable amounts
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        assetsToWithdraw = bound(assetsToWithdraw, 1e6, maxAssets);

        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1, cUSDC_WMON_MARKET);

        assertGt(shares, 0, "Should burn shares");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore + assetsToWithdraw, "Should receive exact assets");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_withdraw_optimalMarket(uint256 assetsToWithdraw) public {
        uint256 depositAmount = 100_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Accrue first so maxWithdraw is accurate
        optimizer.accrueIfNeeded();

        // Bound to reasonable amounts
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        assetsToWithdraw = bound(assetsToWithdraw, 1e6, maxAssets);

        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertGt(shares, 0, "Should burn shares");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore + assetsToWithdraw, "Should receive exact assets");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_withdraw_invariant_exactAssetsReceived(uint256 assetsToWithdraw) public {
        uint256 depositAmount = 100_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Accrue first so maxWithdraw is accurate
        optimizer.accrueIfNeeded();

        // Bound to reasonable amounts
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        assetsToWithdraw = bound(assetsToWithdraw, 1e6, maxAssets);

        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
        optimizer.withdraw(assetsToWithdraw, user1, user1);
        uint256 balanceAfter = IERC20(USDC_MONAD).balanceOf(user1);

        // Core invariant: withdraw always returns exact assets requested
        assertEq(balanceAfter - balanceBefore, assetsToWithdraw, "Must always receive exact assets");

        vm.stopPrank();
    }
}
