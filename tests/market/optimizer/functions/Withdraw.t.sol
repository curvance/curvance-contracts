// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

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
            1_000,
            1 days
        );

        deal(USDC_MONAD, address(this), 77777, true);

        IERC20(USDC_MONAD).approve(address(optimizer), 77777);

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

        uint256 assetsToWithdraw = depositAmount / 2;
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        uint256 sharesBefore = optimizer.balanceOf(user1);
        uint256 assetsBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1, cUSDC_WMON_MARKET);

        assertEq(shares, expectedShares, "Shares burned should match preview");
        assertEq(optimizer.balanceOf(user1), sharesBefore - shares, "Shares should be burned");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), assetsBefore + assetsToWithdraw, "User should receive exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_targetMarketDifferentReceiver() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = depositAmount / 2;
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

        uint256 assetsToWithdraw = depositAmount / 2;
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

        uint256 assetsToWithdraw = depositAmount / 2;
        address fakeMarket = makeAddr("fakeMarket");

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.withdraw(assetsToWithdraw, user1, user1, fakeMarket);

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_targetMarketWithAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        uint256 assetsToWithdraw = depositAmount / 2;
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        // User1 approves user2 for expected shares
        vm.prank(user1);
        optimizer.approve(user2, expectedShares);

        // User2 withdraws on behalf of user1
        vm.startPrank(user2);

        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user2, user1, cUSDC_WMON_MARKET);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assetsToWithdraw, "Caller should receive assets");
        assertEq(optimizer.allowance(user1, user2), 0, "Allowance should be spent");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_fail_targetMarketInsufficientAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        uint256 assetsToWithdraw = depositAmount / 2;
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
        uint256 withdrawAmount = 5_000e6;

        for (uint256 i = 0; i < numWithdraws; i++) {
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

        uint256 assetsToWithdraw = depositAmount / 2;
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        uint256 sharesBefore = optimizer.balanceOf(user1);
        uint256 assetsBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertEq(shares, expectedShares, "Shares burned should match preview");
        assertEq(optimizer.balanceOf(user1), sharesBefore - shares, "Shares should be burned");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), assetsBefore + assetsToWithdraw, "User should receive exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_optimalMarketDifferentReceiver() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = depositAmount / 2;
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        optimizer.withdraw(assetsToWithdraw, user2, user1);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assetsToWithdraw, "Receiver should get exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_optimalMarketEmitsEvent() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = depositAmount / 2;
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
        uint256 withdrawAmount = 10_000e6;

        for (uint256 i = 0; i < numWithdraws; i++) {
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

        // Withdraw most assets (leave some buffer for rounding)
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        uint256 assetsToWithdraw = maxAssets - 1000e6;
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertEq(shares, expectedShares, "Large withdraw should return correct shares");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), assetsToWithdraw, "Should receive exact assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_multipleUsersWithdraw() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);
        _depositForUser(user2, depositAmount);

        uint256 assetsToWithdraw = 5_000e6;

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

        uint256 assetsToWithdraw = 1000e6;

        // First withdraw
        uint256 shares1 = optimizer.withdraw(assetsToWithdraw, user1, user1);

        // Skip time (interest accrues)
        skip(7 days);

        // Trigger yield detection and start vesting
        optimizer.accrueIfNeeded();

        // Skip vesting period to let yield vest
        skip(1 days);

        // Second withdraw - exchange rate should have changed
        uint256 shares2 = optimizer.withdraw(assetsToWithdraw, user1, user1);

        // Both withdraws should burn shares
        assertGt(shares1, 0, "First withdraw should burn shares");
        assertGt(shares2, 0, "Second withdraw should burn shares");

        // Second withdraw should burn FEWER shares (exchange rate increased)
        assertLt(shares2, shares1, "Should burn fewer shares after yield vests");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_previewMatchesActual() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = depositAmount / 2;
        uint256 previewedShares = optimizer.previewWithdraw(assetsToWithdraw);

        uint256 actualShares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertEq(actualShares, previewedShares, "Actual shares should match previewed shares");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_exchangeRateConsistency() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = depositAmount / 2;

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

        uint256 assetsToWithdraw = depositAmount / 2;
        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);

        // User1 approves user2
        vm.prank(user1);
        optimizer.approve(user2, expectedShares);

        // User2 withdraws on behalf of user1
        vm.startPrank(user2);

        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user2, user1);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assetsToWithdraw, "Caller should receive assets");
        assertEq(optimizer.allowance(user1, user2), 0, "Allowance should be spent");

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_success_withInfiniteAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        uint256 assetsToWithdraw = depositAmount / 2;

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

        uint256 assetsToWithdraw = 1000e6;

        // Get expected shares for withdrawing assets
        uint256 sharesForWithdraw = optimizer.previewWithdraw(assetsToWithdraw);

        // Get expected assets for redeeming those shares
        uint256 assetsForRedeem = optimizer.previewRedeem(sharesForWithdraw);

        // They should be equivalent (within rounding)
        uint256 diff = assetsToWithdraw > assetsForRedeem
            ? assetsToWithdraw - assetsForRedeem
            : assetsForRedeem - assetsToWithdraw;

        assertLe(diff, 1, "Withdraw and redeem should be inverse operations");
    }

    // ============ Invariant Tests ============

    function test_lendingOptimizer_withdraw_invariant_exactAssetsReceived() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = 5000e6;

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

        uint256 assetsToWithdraw = 5000e6;

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

        // Track exchange rate across multiple withdraws
        uint256 previousExchangeRate = optimizer.exchangeRate();

        vm.startPrank(user1);

        for (uint256 i = 0; i < 5; i++) {
            uint256 assetsToWithdraw = 5000e6;

            optimizer.withdraw(assetsToWithdraw, user1, user1);

            // Skip time and accrue to simulate yield
            skip(1 days);
            optimizer.accrueIfNeeded();
            skip(1 days); // Let yield vest

            uint256 currentExchangeRate = optimizer.exchangeRate();

            // Exchange rate should never decrease (assuming no losses)
            assertGe(currentExchangeRate, previousExchangeRate, "Exchange rate should never decrease");

            previousExchangeRate = currentExchangeRate;
        }

        vm.stopPrank();
    }

    function test_lendingOptimizer_withdraw_invariant_totalAssetsDecreasesCorrectly() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 assetsToWithdraw = 5000e6;

        uint256 totalAssetsBefore = optimizer.totalAssets();

        optimizer.withdraw(assetsToWithdraw, user1, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();

        // Total assets should decrease by exactly the amount withdrawn
        assertEq(totalAssetsBefore - totalAssetsAfter, assetsToWithdraw, "Total assets should decrease by exact withdrawn amount");

        vm.stopPrank();
    }

    // ============ Fuzz Tests ============

    function testFuzz_lendingOptimizer_withdraw_targetMarket(uint256 assetsToWithdraw) public {
        uint256 depositAmount = 100_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        // Bound to reasonable amounts
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        assetsToWithdraw = bound(assetsToWithdraw, 1e6, maxAssets);

        vm.startPrank(user1);

        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1, cUSDC_WMON_MARKET);

        assertEq(shares, expectedShares, "Shares should match preview");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore + assetsToWithdraw, "Should receive exact assets");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_withdraw_optimalMarket(uint256 assetsToWithdraw) public {
        uint256 depositAmount = 100_000e6;
        _depositForUser(user1, depositAmount);

        // Bound to reasonable amounts
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        assetsToWithdraw = bound(assetsToWithdraw, 1e6, maxAssets);

        vm.startPrank(user1);

        uint256 expectedShares = optimizer.previewWithdraw(assetsToWithdraw);
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 shares = optimizer.withdraw(assetsToWithdraw, user1, user1);

        assertEq(shares, expectedShares, "Shares should match preview");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore + assetsToWithdraw, "Should receive exact assets");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_withdraw_invariant_exactAssetsReceived(uint256 assetsToWithdraw) public {
        uint256 depositAmount = 100_000e6;
        _depositForUser(user1, depositAmount);

        // Bound to reasonable amounts
        uint256 maxAssets = optimizer.maxWithdraw(user1);
        assetsToWithdraw = bound(assetsToWithdraw, 1e6, maxAssets);

        vm.startPrank(user1);

        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
        optimizer.withdraw(assetsToWithdraw, user1, user1);
        uint256 balanceAfter = IERC20(USDC_MONAD).balanceOf(user1);

        // Core invariant: withdraw always returns exact assets requested
        assertEq(balanceAfter - balanceBefore, assetsToWithdraw, "Must always receive exact assets");

        vm.stopPrank();
    }
}
