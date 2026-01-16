// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestLendingOptimizerRedeem is TestBaseLendingOptimizer {

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

    // ============ redeem(shares, receiver, owner, targetMarket) Tests ============

    function test_lendingOptimizer_redeem_success_targetMarketZ() public {
        // Deposit first
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;
        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);

        uint256 sharesBefore = optimizer.balanceOf(user1);
        uint256 assetsBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1, cUSDC_WMON_MARKET);

        // Allow 0-2 wei variance due to: (1) cToken interest accruing between previewRedeem and redeem,
        // and (2) fee dilution when yield is detected.
        assertApproxEqAbs(assets, expectedAssets, 2, "Assets redeemed should approximately match preview");
        assertEq(optimizer.balanceOf(user1), sharesBefore - sharesToRedeem, "Shares should be burned");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), assetsBefore + assets, "User should receive assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_targetMarketDifferentReceiver() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        // Redeem with user2 as receiver
        uint256 assets = optimizer.redeem(sharesToRedeem, user2, user1, cUSDC_WMON_MARKET);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assets, "Receiver should get assets");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), 0, "Owner should not receive assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_targetMarketAllMarkets() public {
        // Deposit to each market
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WETH_MARKET, cUSDC_WBTC_MARKET];
        uint256 depositAmount = 10_000e6;

        for (uint256 i = 0; i < markets.length; i++) {
            _depositToMarket(user1, depositAmount, markets[i]);
        }

        vm.startPrank(user1);

        // Redeem from each market
        for (uint256 i = 0; i < markets.length; i++) {
            uint256 sharesToRedeem = 1000e6;
            uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

            uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1, markets[i]);

            assertGt(assets, 0, "Should receive assets");
            assertEq(
                IERC20(USDC_MONAD).balanceOf(user1),
                balanceBefore + assets,
                "Balance should increase"
            );
        }

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_targetMarketEmitsEvent() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;

        // Call accrueIfNeeded first so previewRedeem matches the internal call.
        optimizer.accrueIfNeeded();
        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(user1, user1, user1, expectedAssets, sharesToRedeem);

        optimizer.redeem(sharesToRedeem, user1, user1, cUSDC_WMON_MARKET);

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_fail_targetMarketNotApproved() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;
        address fakeMarket = makeAddr("fakeMarket");

        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.redeem(sharesToRedeem, user1, user1, fakeMarket);

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_targetMarketWithAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;

        // User1 approves user2
        vm.prank(user1);
        optimizer.approve(user2, sharesToRedeem);

        // User2 redeems on behalf of user1
        vm.startPrank(user2);

        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        uint256 assets = optimizer.redeem(sharesToRedeem, user2, user1, cUSDC_WMON_MARKET);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assets, "Caller should receive assets");
        assertEq(optimizer.allowance(user1, user2), 0, "Allowance should be spent");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_fail_targetMarketInsufficientAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;

        // User1 approves less than needed
        vm.prank(user1);
        optimizer.approve(user2, sharesToRedeem / 2);

        // User2 tries to redeem more than allowed
        vm.startPrank(user2);

        vm.expectRevert();
        optimizer.redeem(sharesToRedeem, user2, user1, cUSDC_WMON_MARKET);

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_targetMarketMultipleRedeems() public {
        uint256 depositAmount = 50_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        vm.startPrank(user1);

        uint256 numRedeems = 5;
        uint256 redeemAmount = 5_000e6;

        for (uint256 i = 0; i < numRedeems; i++) {
            uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
            uint256 sharesBefore = optimizer.balanceOf(user1);

            uint256 assets = optimizer.redeem(redeemAmount, user1, user1, cUSDC_WMON_MARKET);

            assertGt(assets, 0, "Should receive assets");
            assertEq(optimizer.balanceOf(user1), sharesBefore - redeemAmount, "Shares should decrease");
            assertEq(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore + assets, "Balance should increase");
        }

        vm.stopPrank();
    }

    // ============ redeem(shares, receiver, owner) - ERC4626 Standard Tests ============

    function test_lendingOptimizer_redeem_success_optimalMarket() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;
        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);

        uint256 sharesBefore = optimizer.balanceOf(user1);
        uint256 assetsBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(assets, expectedAssets, 2, "Assets redeemed should approximately match preview");
        assertEq(optimizer.balanceOf(user1), sharesBefore - sharesToRedeem, "Shares should be burned");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), assetsBefore + assets, "User should receive assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_optimalMarketDifferentReceiver() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        uint256 assets = optimizer.redeem(sharesToRedeem, user2, user1);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assets, "Receiver should get assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_optimalMarketEmitsEvent() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;

        // Call accrueIfNeeded first so previewRedeem matches the internal call.
        optimizer.accrueIfNeeded();
        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(user1, user1, user1, expectedAssets, sharesToRedeem);

        optimizer.redeem(sharesToRedeem, user1, user1);

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_optimalMarketSelectsCorrectly() public {
        // Deposit to multiple markets
        _depositToMarket(user1, 50_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(user1, 30_000e6, cUSDC_WBTC_MARKET);

        vm.startPrank(user1);

        uint256 sharesToRedeem = 10_000e6;
        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);

        // Get the expected optimal target before redeem
        uint256 expectedTarget = optimizer.optimalWithdrawalTarget(expectedAssets);
        address expectedMarket = optimizer.approvedCTokensList(expectedTarget);

        // Get market balance before
        uint256 marketBalanceBefore = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));

        optimizer.redeem(sharesToRedeem, user1, user1);

        // Verify redeem came from the expected market
        uint256 marketBalanceAfter = IBorrowableCToken(expectedMarket).balanceOf(address(optimizer));
        assertLt(marketBalanceAfter, marketBalanceBefore, "Expected market should have reduced balance");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_optimalMarketMultipleRedeems() public {
        uint256 depositAmount = 100_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 numRedeems = 5;
        uint256 redeemAmount = 10_000e6;

        for (uint256 i = 0; i < numRedeems; i++) {
            uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
            uint256 sharesBefore = optimizer.balanceOf(user1);

            uint256 assets = optimizer.redeem(redeemAmount, user1, user1);

            assertGt(assets, 0, "Should receive assets");
            assertLt(optimizer.balanceOf(user1), sharesBefore, "Shares should decrease");
            assertGt(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore, "Balance should increase");
        }

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_smallAmount() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Redeem 1 share (smallest meaningful amount)
        uint256 sharesToRedeem = 1e6;
        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1);

        assertGt(assets, 0, "Should receive assets even for small redeem");
        assertGt(IERC20(USDC_MONAD).balanceOf(user1), balanceBefore, "Balance should increase");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_largeAmount() public {
        uint256 depositAmount = 1_000_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        // Redeem most shares
        uint256 sharesToRedeem = optimizer.balanceOf(user1) - 1000e6; // Leave some buffer
        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(assets, expectedAssets, 2, "Large redeem should return approximately correct assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_multipleUsersRedeem() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);
        _depositForUser(user2, depositAmount);

        uint256 sharesToRedeem = 5_000e6;

        // User1 redeems
        vm.startPrank(user1);
        uint256 user1BalanceBefore = IERC20(USDC_MONAD).balanceOf(user1);
        uint256 assets1 = optimizer.redeem(sharesToRedeem, user1, user1);
        vm.stopPrank();

        // User2 redeems
        vm.startPrank(user2);
        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);
        uint256 assets2 = optimizer.redeem(sharesToRedeem, user2, user2);
        vm.stopPrank();

        assertGt(assets1, 0, "User1 should receive assets");
        assertGt(assets2, 0, "User2 should receive assets");
        assertEq(IERC20(USDC_MONAD).balanceOf(user1), user1BalanceBefore + assets1, "User1 balance should increase");
        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assets2, "User2 balance should increase");
    }

    function test_lendingOptimizer_redeem_success_afterTimePasses() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = 1000e6;

        // First redeem
        uint256 assets1 = optimizer.redeem(sharesToRedeem, user1, user1);

        // Skip time (interest accrues)
        skip(7 days);

        // Trigger yield detection and start vesting
        optimizer.accrueIfNeeded();

        // Skip vesting period to let yield vest
        skip(1 days);

        // Second redeem - exchange rate should have changed
        uint256 assets2 = optimizer.redeem(sharesToRedeem, user1, user1);

        // Both redeems should return assets
        assertGt(assets1, 0, "First redeem should return assets");
        assertGt(assets2, 0, "Second redeem should return assets");

        // Second redeem should return MORE assets (exchange rate increased)
        assertGt(assets2, assets1, "Should receive more assets after yield vests");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_previewMatchesActual() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;
        uint256 previewedAssets = optimizer.previewRedeem(sharesToRedeem);

        uint256 actualAssets = optimizer.redeem(sharesToRedeem, user1, user1);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(actualAssets, previewedAssets, 2, "Actual assets should approximately match previewed assets");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_exchangeRateConsistency() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;

        // Call accrueIfNeeded first to capture post-accrual state.
        // This ensures fee minting happens before we measure totalSupplyBefore.
        optimizer.accrueIfNeeded();

        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();
        uint256 totalSupplyAfter = optimizer.totalSupply();

        // Verify supply decreased by exact shares redeemed
        assertEq(totalSupplyAfter, totalSupplyBefore - sharesToRedeem, "Supply should decrease by exact shares");

        // Verify assets decreased by redeemed amount
        assertEq(totalAssetsAfter, totalAssetsBefore - assets, "Assets should decrease by redeemed amount");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_fullRedeem() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 allShares = optimizer.balanceOf(user1);

        uint256 assets = optimizer.redeem(allShares, user1, user1);

        assertGt(assets, 0, "Should receive assets");
        assertEq(optimizer.balanceOf(user1), 0, "Should have no shares left");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_fail_insufficientShares() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 tooManyShares = optimizer.balanceOf(user1) + 1e6;

        vm.expectRevert();
        optimizer.redeem(tooManyShares, user1, user1);

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_withAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;

        // User1 approves user2
        vm.prank(user1);
        optimizer.approve(user2, sharesToRedeem);

        // User2 redeems on behalf of user1
        vm.startPrank(user2);

        uint256 user2BalanceBefore = IERC20(USDC_MONAD).balanceOf(user2);

        uint256 assets = optimizer.redeem(sharesToRedeem, user2, user1);

        assertEq(IERC20(USDC_MONAD).balanceOf(user2), user2BalanceBefore + assets, "Caller should receive assets");
        assertEq(optimizer.allowance(user1, user2), 0, "Allowance should be spent");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_success_withInfiniteAllowance() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        uint256 sharesToRedeem = optimizer.balanceOf(user1) / 2;

        // User1 approves max uint256
        vm.prank(user1);
        optimizer.approve(user2, type(uint256).max);

        // User2 redeems on behalf of user1
        vm.startPrank(user2);

        optimizer.redeem(sharesToRedeem, user2, user1);

        // Allowance should remain max (infinite approval)
        assertEq(optimizer.allowance(user1, user2), type(uint256).max, "Infinite allowance should persist");

        vm.stopPrank();
    }

    // ============ Redeem vs Withdraw Equivalence Tests ============

    function test_lendingOptimizer_redeem_withdrawEquivalence() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        uint256 sharesToRedeem = 1000e6;

        // Get expected assets for redeeming shares
        uint256 assetsForRedeem = optimizer.previewRedeem(sharesToRedeem);

        // Get expected shares for withdrawing those assets
        uint256 sharesForWithdraw = optimizer.previewWithdraw(assetsForRedeem);

        // They should be equivalent (within rounding)
        uint256 diff = sharesToRedeem > sharesForWithdraw
            ? sharesToRedeem - sharesForWithdraw
            : sharesForWithdraw - sharesToRedeem;

        assertLe(diff, 1, "Redeem and withdraw should be inverse operations");
    }

    // ============ Invariant Tests ============

    function test_lendingOptimizer_redeem_invariant_exactSharesBurned() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = 5000e6;

        uint256 sharesBefore = optimizer.balanceOf(user1);
        optimizer.redeem(sharesToRedeem, user1, user1);
        uint256 sharesAfter = optimizer.balanceOf(user1);

        // Redeem should always burn exact shares requested
        assertEq(sharesBefore - sharesAfter, sharesToRedeem, "Must burn exact shares requested");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_invariant_assetsMatchFormula() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = 5000e6;

        // Accrue first to get post-accrual state
        optimizer.accrueIfNeeded();
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();

        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);
        uint256 actualAssets = optimizer.redeem(sharesToRedeem, user1, user1);

        // Verify the ERC4626 formula: assets = shares * totalAssets / totalSupply (round down)
        uint256 calculatedAssets = (sharesToRedeem * totalAssetsBefore) / totalSupplyBefore;

        // Allow for small rounding difference
        uint256 diff = actualAssets > calculatedAssets
            ? actualAssets - calculatedAssets
            : calculatedAssets - actualAssets;

        assertLe(diff, 1, "Assets should match formula calculation");

        vm.stopPrank();
    }

    function test_lendingOptimizer_redeem_invariant_exchangeRateNeverDecreases() public {
        uint256 depositAmount = 50_000e6;
        _depositForUser(user1, depositAmount);

        // Track exchange rate across multiple redeems
        uint256 previousExchangeRate = optimizer.exchangeRate();

        vm.startPrank(user1);

        for (uint256 i = 0; i < 5; i++) {
            uint256 sharesToRedeem = 5000e6;

            optimizer.redeem(sharesToRedeem, user1, user1);

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

    function test_lendingOptimizer_redeem_invariant_totalAssetsDecreasesCorrectly() public {
        uint256 depositAmount = 10_000e6;
        _depositForUser(user1, depositAmount);

        vm.startPrank(user1);

        uint256 sharesToRedeem = 5000e6;

        uint256 totalAssetsBefore = optimizer.totalAssets();

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1);

        uint256 totalAssetsAfter = optimizer.totalAssets();

        // Total assets should decrease by exactly the amount withdrawn
        assertEq(totalAssetsBefore - totalAssetsAfter, assets, "Total assets should decrease by redeemed amount");

        vm.stopPrank();
    }

    // ============ Fuzz Tests ============

    function testFuzz_lendingOptimizer_redeem_targetMarket(uint256 sharesToRedeem) public {
        uint256 depositAmount = 100_000e6;
        _depositToMarket(user1, depositAmount, cUSDC_WMON_MARKET);

        // Bound to reasonable amounts
        uint256 maxShares = optimizer.balanceOf(user1);
        sharesToRedeem = bound(sharesToRedeem, 1e6, maxShares);

        vm.startPrank(user1);

        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);
        uint256 sharesBefore = optimizer.balanceOf(user1);

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1, cUSDC_WMON_MARKET);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(assets, expectedAssets, 2, "Assets should approximately match preview");
        assertEq(optimizer.balanceOf(user1), sharesBefore - sharesToRedeem, "Shares should be burned");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_redeem_optimalMarket(uint256 sharesToRedeem) public {
        uint256 depositAmount = 100_000e6;
        _depositForUser(user1, depositAmount);

        // Bound to reasonable amounts
        uint256 maxShares = optimizer.balanceOf(user1);
        sharesToRedeem = bound(sharesToRedeem, 1e6, maxShares);

        vm.startPrank(user1);

        uint256 expectedAssets = optimizer.previewRedeem(sharesToRedeem);
        uint256 sharesBefore = optimizer.balanceOf(user1);

        uint256 assets = optimizer.redeem(sharesToRedeem, user1, user1);

        // Allow 0-2 wei variance due to cToken interest accrual and fee dilution.
        assertApproxEqAbs(assets, expectedAssets, 2, "Assets should approximately match preview");
        assertEq(optimizer.balanceOf(user1), sharesBefore - sharesToRedeem, "Shares should be burned");

        vm.stopPrank();
    }

    function testFuzz_lendingOptimizer_redeem_invariant_exactSharesBurned(uint256 sharesToRedeem) public {
        uint256 depositAmount = 100_000e6;
        _depositForUser(user1, depositAmount);

        // Bound to reasonable amounts
        uint256 maxShares = optimizer.balanceOf(user1);
        sharesToRedeem = bound(sharesToRedeem, 1e6, maxShares);

        vm.startPrank(user1);

        uint256 sharesBefore = optimizer.balanceOf(user1);
        optimizer.redeem(sharesToRedeem, user1, user1);
        uint256 sharesAfter = optimizer.balanceOf(user1);

        // Core invariant: redeem always burns exact shares requested
        assertEq(sharesBefore - sharesAfter, sharesToRedeem, "Must always burn exact shares");

        vm.stopPrank();
    }
}

