// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestAccrueOnTwoBorrwables is TestBaseMarketIsolated {

    address lp;

    function setUp() public override {
        super.setUp();
        _prepareUSDC(address(this), 77777);
        _prepareDAI(address(this), 77777);

        usdc.approve(address(borrowableCUSDC), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        // List two borrowable cTokens in the market.
        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        // Set config for both tokens with 0 debt cap.
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.collRatio = 9500; 
        tokenConfig.collReqSoft = 300;
        tokenConfig.collReqHard = 250;
        tokenConfig.liqIncBase = 125;
        tokenConfig.liqIncHard = 150;
        tokenConfig.liqIncMin = 125;
        tokenConfig.liqIncMax = 150;
        tokenConfig.closeFactorBase = 4000;
        tokenConfig.closeFactorMin = 4000;
        tokenConfig.closeFactorMax = 10_000;
        tokenConfig.collateralCap = 3000000e6;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        MarketManagerIsolated.TokenConfig memory tokenConfig2;
        tokenConfig2.cToken = address(borrowableCDAI);
        tokenConfig2.collRatio = 9500; 
        tokenConfig2.collReqSoft = 300;
        tokenConfig2.collReqHard = 250;
        tokenConfig2.liqIncBase = 125;
        tokenConfig2.liqIncHard = 150;
        tokenConfig2.liqIncMin = 125;
        tokenConfig2.liqIncMax = 150;
        tokenConfig2.closeFactorBase = 4000;
        tokenConfig2.closeFactorMin = 4000;
        tokenConfig2.closeFactorMax = 10_000;
        tokenConfig2.collateralCap = 30000000e18;
        tokenConfig2.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig2);

        // Provide liquidity to both markets
        lp = makeAddr("liquidityProvider");
        _prepareUSDC(lp, 1_000e6);
        _prepareDAI(lp, 1_000e18);

        vm.startPrank(lp);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        borrowableCUSDC.deposit(500e6, lp);
        borrowableCDAI.deposit(500e18, lp);
        vm.stopPrank();
    }

    function test_setupMarketWithTwoBorrowableTokens_success() public {

        // Supply and totalAssets should equal 77777 (initialization deposit) + 500e6 / 500e18.
        assertEq(borrowableCUSDC.totalSupply(), 77777 + 500e6, "cUSDC supply after initial LP deposit");
        assertEq(borrowableCUSDC.totalAssets(), 77777 + 500e6, "cUSDC assets after initial LP deposit");
        assertEq(borrowableCDAI.totalSupply(), 77777 + 500e18, "cDAI supply after initial LP deposit");
        assertEq(borrowableCDAI.totalAssets(), 77777 + 500e18, "cDAI assets after initial LP deposit");

        // User posts some collateral in both borrowable tokens
        _prepareUSDC(user1, 100e6);
        _prepareDAI(user1, 100e18);

        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        borrowableCUSDC.depositAsCollateral(10e6, user1);
        borrowableCDAI.depositAsCollateral(10e18, user1);
        vm.stopPrank();

        // Exact post-conditions for user1 collateral deposit (1:1 shares with zero interest)
        assertEq(borrowableCUSDC.balanceOf(user1), 10e6, "cUSDC user1 shares after collateral deposit");
        assertEq(borrowableCUSDC.collateralPosted(user1), 10e6, "cUSDC user1 collateralPosted");
        assertEq(borrowableCUSDC.marketCollateralPosted(), 10e6, "cUSDC marketCollateralPosted");
        assertEq(borrowableCUSDC.totalSupply(), 77777 + 500e6 + 10e6, "cUSDC supply after user collateral deposit");
        assertEq(borrowableCUSDC.totalAssets(), 77777 + 500e6 + 10e6, "cUSDC assets after user collateral deposit");

        assertEq(borrowableCDAI.balanceOf(user1), 10e18, "cDAI user1 shares after collateral deposit");
        assertEq(borrowableCDAI.collateralPosted(user1), 10e18, "cDAI user1 collateralPosted");
        assertEq(borrowableCDAI.marketCollateralPosted(), 10e18, "cDAI marketCollateralPosted");
        assertEq(borrowableCDAI.totalSupply(), 77777 + 500e18 + 10e18, "cDAI supply after user collateral deposit");
        assertEq(borrowableCDAI.totalAssets(), 77777 + 500e18 + 10e18, "cDAI assets after user collateral deposit");

        // With debt caps set to 0, no one can borrow. Accrual should be a no-op
        uint256 cUSDCSupply0 = borrowableCUSDC.totalSupply();
        uint256 cUSDCAssets0 = borrowableCUSDC.totalAssets();
        uint256 cUSDCDebt0 = borrowableCUSDC.marketOutstandingDebt();
        uint256 cUSDCUserColl0 = borrowableCUSDC.collateralPosted(user1);

        uint256 cDAISupply0 = borrowableCDAI.totalSupply();
        uint256 cDAIAssets0 = borrowableCDAI.totalAssets();
        uint256 cDAIDebt0 = borrowableCDAI.marketOutstandingDebt();
        uint256 cDAIUserColl0 = borrowableCDAI.collateralPosted(user1);

        // Accrue immediately in the same block
        borrowableCUSDC.accrueIfNeeded();
        borrowableCDAI.accrueIfNeeded();

        assertEq(borrowableCUSDC.marketOutstandingDebt(), 0, "cUSDC debt should remain zero");
        assertEq(borrowableCDAI.marketOutstandingDebt(), 0, "cDAI debt should remain zero");
        assertEq(borrowableCUSDC.totalSupply(), cUSDCSupply0, "cUSDC supply unchanged with zero-debt accrual");
        assertEq(borrowableCUSDC.totalAssets(), cUSDCAssets0, "cUSDC assets unchanged with zero-debt accrual");
        assertEq(borrowableCUSDC.collateralPosted(user1), cUSDCUserColl0, "cUSDC collateral unchanged by accrual");
        assertEq(borrowableCDAI.totalSupply(), cDAISupply0, "cDAI supply unchanged with zero-debt accrual");
        assertEq(borrowableCDAI.totalAssets(), cDAIAssets0, "cDAI assets unchanged with zero-debt accrual");
        assertEq(borrowableCDAI.collateralPosted(user1), cDAIUserColl0, "cDAI collateral unchanged by accrual");

        // Advance time, accrual still should not change anything with zero debt
        skip(1 hours);
        borrowableCUSDC.accrueIfNeeded();
        borrowableCDAI.accrueIfNeeded();

        assertEq(borrowableCUSDC.marketOutstandingDebt(), 0, "cUSDC debt should remain zero after time");
        assertEq(borrowableCDAI.marketOutstandingDebt(), 0, "cDAI debt should remain zero after time");
        assertEq(borrowableCUSDC.totalSupply(), cUSDCSupply0, "cUSDC supply unchanged after time");
        assertEq(borrowableCUSDC.totalAssets(), cUSDCAssets0, "cUSDC assets unchanged after time");
        assertEq(borrowableCUSDC.collateralPosted(user1), cUSDCUserColl0, "cUSDC collateral unchanged after time");
        assertEq(borrowableCDAI.totalSupply(), cDAISupply0, "cDAI supply unchanged after time");
        assertEq(borrowableCDAI.totalAssets(), cDAIAssets0, "cDAI assets unchanged after time");
        assertEq(borrowableCDAI.collateralPosted(user1), cDAIUserColl0, "cDAI collateral unchanged after time");

        // Add additional deposit for normal activity
        vm.startPrank(lp);
        borrowableCUSDC.deposit(250e6, lp);
        borrowableCDAI.deposit(250e18, lp);
        vm.stopPrank();

        // Exact post-conditions for additional LP deposits (no interest accrued)
        assertEq(borrowableCUSDC.totalSupply(), cUSDCSupply0 + 250e6, "cUSDC supply after additional LP deposit");
        assertEq(borrowableCUSDC.totalAssets(), cUSDCAssets0 + 250e6, "cUSDC assets after additional LP deposit");
        assertEq(borrowableCUSDC.balanceOf(lp), 750e6, "cUSDC LP shares after both deposits");

        assertEq(borrowableCDAI.totalSupply(), cDAISupply0 + 250e18, "cDAI supply after additional LP deposit");
        assertEq(borrowableCDAI.totalAssets(), cDAIAssets0 + 250e18, "cDAI assets after additional LP deposit");
        assertEq(borrowableCDAI.balanceOf(lp), 750e18, "cDAI LP shares after both deposits");

        // Accrue again. Accrue should still be safe and not introduce debt
        borrowableCUSDC.accrueIfNeeded();
        borrowableCDAI.accrueIfNeeded();
        assertEq(borrowableCUSDC.marketOutstandingDebt(), 0, "cUSDC debt should remain zero after more activity");
        assertEq(borrowableCDAI.marketOutstandingDebt(), 0, "cDAI debt should remain zero after more activity");

        // Exact non-changes post accrual
        assertEq(borrowableCUSDC.totalSupply(), cUSDCSupply0 + 250e6, "cUSDC supply unchanged by accrual after additional deposit");
        assertEq(borrowableCUSDC.totalAssets(), cUSDCAssets0 + 250e6, "cUSDC assets unchanged by accrual after additional deposit");
        assertEq(borrowableCDAI.totalSupply(), cDAISupply0 + 250e18, "cDAI supply unchanged by accrual after additional deposit");
        assertEq(borrowableCDAI.totalAssets(), cDAIAssets0 + 250e18, "cDAI assets unchanged by accrual after additional deposit");

        // Let more time pass. Accrue should continue to be a no-op for zero debt
        skip(2 days);
        borrowableCUSDC.accrueIfNeeded();
        borrowableCDAI.accrueIfNeeded();
        assertEq(borrowableCUSDC.marketOutstandingDebt(), 0, "cUSDC debt should remain zero after 2 days");
        assertEq(borrowableCDAI.marketOutstandingDebt(), 0, "cDAI debt should remain zero after 2 days");

        // Exact non-changes post time and accrual.
        assertEq(borrowableCUSDC.totalSupply(), cUSDCSupply0 + 250e6, "cUSDC supply unchanged after 2 days");
        assertEq(borrowableCUSDC.totalAssets(), cUSDCAssets0 + 250e6, "cUSDC assets unchanged after 2 days");
        assertEq(borrowableCDAI.totalSupply(), cDAISupply0 + 250e18, "cDAI supply unchanged after 2 days");
        assertEq(borrowableCDAI.totalAssets(), cDAIAssets0 + 250e18, "cDAI assets unchanged after 2 days");

        // With debt caps at 0, borrowing should revert due to cap reached
        vm.startPrank(user2);
        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        borrowableCUSDC.borrow(1e6, user2);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        borrowableCDAI.borrow(1e18, user2);
        vm.stopPrank();

        // Repeated accruals and yield info checks
        for (uint256 i = 0; i < 5; i++) {
            skip(30 minutes);
            borrowableCUSDC.accrueIfNeeded();
            borrowableCDAI.accrueIfNeeded();

            // debt should remain zero
            assertEq(borrowableCUSDC.marketOutstandingDebt(), 0, "cUSDC debt remains zero during accrual loop");
            assertEq(borrowableCDAI.marketOutstandingDebt(), 0, "cDAI debt remains zero during accrual loop");
        }

        // Check getYieldInformation after accrues
        (uint256 rateUsdc, uint256 vestEndUsdc, uint256 lastVestUsdc, uint256 debtIndexUsdc) =
            borrowableCUSDC.getYieldInformation();
        (uint256 rateDai, uint256 vestEndDai, uint256 lastVestDai, uint256 debtIndexDai) =
            borrowableCDAI.getYieldInformation();

        // With zero debt, debt index should remain WAD.
        assertEq(debtIndexUsdc, 1e18, "cUSDC debtIndex should remain WAD");
        assertEq(debtIndexDai, 1e18, "cDAI debtIndex should remain WAD");

        // vestingEnd should be in the future, lastVestingClaim should be current timestamp.
        assertGt(vestEndUsdc, block.timestamp, "cUSDC vestingEnd should be in the future");
        assertGt(vestEndDai, block.timestamp, "cDAI vestingEnd should be in the future");
        assertEq(lastVestUsdc, block.timestamp, "cUSDC lastVestingClaim updated to now");
        assertEq(lastVestDai, block.timestamp, "cDAI lastVestingClaim updated to now");

        // Vesting rate should be zero
        assertEq(rateUsdc, 0, "cUSDC vestingRate should be 0");
        assertEq(rateDai, 0, "cDAI vestingRate should be 0");

        // Confirm deposits/collateralization/redeems are not blocked
        (bool mintPausedUsdc, bool collPausedUsdc, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC));
        (bool mintPausedDai, bool collPausedDai, ) = marketManagerIsolated.actionsPaused(address(borrowableCDAI));
        assertTrue(!mintPausedUsdc && !collPausedUsdc, "cUSDC actions should not be paused");
        assertTrue(!mintPausedDai && !collPausedDai, "cDAI actions should not be paused");

        // Confirm withdrawal by LP still works
        uint256 lpUsdcBalSharesBefore = borrowableCUSDC.balanceOf(lp);
        uint256 lpDaiBalSharesBefore = borrowableCDAI.balanceOf(lp);
        vm.startPrank(lp);
        uint256 usdcWithdrawShares = borrowableCUSDC.previewWithdraw(100e6);
        uint256 daiWithdrawShares = borrowableCDAI.previewWithdraw(100e18);
        borrowableCUSDC.withdraw(100e6, lp, lp);
        borrowableCDAI.withdraw(100e18, lp, lp);
        vm.stopPrank();
        assertEq(borrowableCUSDC.balanceOf(lp), lpUsdcBalSharesBefore - usdcWithdrawShares, "LP cUSDC share balance reduced correctly");
        assertEq(borrowableCDAI.balanceOf(lp), lpDaiBalSharesBefore - daiWithdrawShares, "LP cDAI share balance reduced correctly");

        _refreshMockFeeds();

        // Collateral redemption by user1 works
        // hold period already passed
        uint256 user1UsdcCollBefore = borrowableCUSDC.collateralPosted(user1);
        uint256 user1DaiCollBefore = borrowableCDAI.collateralPosted(user1);
        vm.startPrank(user1);
        borrowableCUSDC.redeemCollateral(5e6, user1, user1);
        borrowableCDAI.redeemCollateral(5e18, user1, user1);
        vm.stopPrank();

        assertEq(borrowableCUSDC.collateralPosted(user1), user1UsdcCollBefore - 5e6, "user1 cUSDC collateral reduced");
        assertEq(borrowableCDAI.collateralPosted(user1), user1DaiCollBefore - 5e18, "user1 cDAI collateral reduced");

        // New deposits still work post accruals
        address depositor = makeAddr("newDepositor");
        _prepareUSDC(depositor, 42e6);
        _prepareDAI(depositor, 42e18);
        vm.startPrank(depositor);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        uint256 cUSDCSupplyPreDeposit = borrowableCUSDC.totalSupply();
        uint256 cUSDCAssetsPreDeposit = borrowableCUSDC.totalAssets();
        uint256 cDAISupplyPreDeposit = borrowableCDAI.totalSupply();
        uint256 cDAIAssetsPreDeposit = borrowableCDAI.totalAssets();
        borrowableCUSDC.deposit(42e6, depositor);
        borrowableCDAI.deposit(42e18, depositor);
        vm.stopPrank();

        // Assert accounting works correctly final last deposit
        assertEq(borrowableCUSDC.totalSupply(), cUSDCSupplyPreDeposit + 42e6, "cUSDC supply increased by depositor amount");
        assertEq(borrowableCUSDC.totalAssets(), cUSDCAssetsPreDeposit + 42e6, "cUSDC assets increased by depositor amount");
        assertEq(borrowableCDAI.totalSupply(), cDAISupplyPreDeposit + 42e18, "cDAI supply increased by depositor amount");
        assertEq(borrowableCDAI.totalAssets(), cDAIAssetsPreDeposit + 42e18, "cDAI assets increased by depositor amount");
    }
}


