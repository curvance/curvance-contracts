// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

contract RemoveCollateralFuzzed is TestBaseMarketIsolated {
	function setUp() override public {
		super.setUp();

		_prepareDAI(address(this), 77777);
		_prepareUSDC(address(this), 77777);

		dai.approve(address(borrowableCDAI), 77777);
		usdc.approve(address(borrowableCUSDC), 77777);

		marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        mockUsdcFeed.setMockAnswer(1e8);
        mockDaiFeed.setMockAnswer(1e8);
	}

	function test_fuzz_removeCollateral_success(
		uint256 initialDeposit,
		uint256 sharesToRemove
	) public {

		_setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 10_000_000e18);
		_setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 10_000_000e6);

		initialDeposit = bound(initialDeposit, 1e18, 1_000_000e18);
		_prepareDAI(user1, initialDeposit);

		vm.startPrank(user1);
		dai.approve(address(borrowableCDAI), initialDeposit);
		borrowableCDAI.depositAsCollateral(initialDeposit, user1);
		vm.stopPrank();

		skip(20 minutes);

		uint256 userBalBefore = borrowableCDAI.balanceOf(user1);
		uint256 userCollBefore = borrowableCDAI.collateralPosted(user1);
		uint256 marketCollBefore = borrowableCDAI.marketCollateralPosted();

		sharesToRemove = bound(sharesToRemove, 1, userCollBefore);

		vm.startPrank(user1);
		borrowableCDAI.removeCollateral(sharesToRemove);
		vm.stopPrank();

		assertEq(borrowableCDAI.balanceOf(user1), userBalBefore, "balance should not change");
		assertEq(
			borrowableCDAI.collateralPosted(user1),
			userCollBefore - sharesToRemove,
			"user collateral should decrease exactly"
		);
		assertEq(
			borrowableCDAI.marketCollateralPosted(),
			marketCollBefore - sharesToRemove,
			"market collateral should decrease exactly"
		);
	}

	function test_fuzz_RemoveCollateral_fail_whenInsufficientLiquidity(
		uint256 initialDeposit,
		uint256 tooMuch
	) public {
		_setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 10_000_000e18);
		_setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 10_000_000e6);

		initialDeposit = bound(initialDeposit, 1e18, 1_000_000e18);
		_prepareDAI(user1, initialDeposit);

		vm.startPrank(user1);
		dai.approve(address(borrowableCDAI), initialDeposit);
		borrowableCDAI.depositAsCollateral(initialDeposit, user1);
		vm.stopPrank();

		skip(20 minutes);

		uint256 posted = borrowableCDAI.collateralPosted(user1);
		tooMuch = bound(tooMuch, posted + 1, posted * 5);

		vm.startPrank(user1);
		vm.expectRevert(BaseCToken.BaseCToken__InsufficientLiquidity.selector);
		borrowableCDAI.removeCollateral(tooMuch);
		vm.stopPrank();
	}

	function test_fuzz_RemoveCollateral_fail_whenRemovingAllCollateralWhenBorrowing(
		uint256 initialDeposit,
		uint256 borrowAmount
	) public {
		_setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 10_000_000e18);
		_setCTokenConfigBasic(address(borrowableCUSDC), 10_000_000e6, 10_000_000e6);

		vm.startPrank(user2);
		_prepareUSDC(user2, 10_000_000e6);
		usdc.approve(address(borrowableCUSDC), 10_000_000e6);
		borrowableCUSDC.deposit(10_000_000e6, user2);
		vm.stopPrank();

		initialDeposit = bound(initialDeposit, 100e18, 1_000_000e18);
		_prepareDAI(user1, initialDeposit);

		vm.startPrank(user1);
		dai.approve(address(borrowableCDAI), initialDeposit);
		borrowableCDAI.depositAsCollateral(initialDeposit, user1);
		vm.stopPrank();

		borrowAmount = bound(borrowAmount, 50e6, (initialDeposit * 6000 / 10000) / 1e12);
		vm.startPrank(user1);
		borrowableCUSDC.borrow(borrowAmount, user1);
		vm.stopPrank();

		skip(20 minutes);

		uint256 posted = borrowableCDAI.collateralPosted(user1);

		vm.startPrank(user1);
		vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
		borrowableCDAI.removeCollateral(posted);
		vm.stopPrank();
	}

	function test_fuzz_RemoveCollateral_fail_whenRemovingBeforeCooldown(
		uint256 initialDeposit,
		uint256 removalAttempt
	) public {
		_setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 10_000_000e18);
		_setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 10_000_000e6);

		initialDeposit = bound(initialDeposit, 1e18, 1_000_000e18);
		_prepareDAI(user1, initialDeposit);

		vm.startPrank(user1);
		dai.approve(address(borrowableCDAI), initialDeposit);
		borrowableCDAI.depositAsCollateral(initialDeposit, user1);

		uint256 posted = borrowableCDAI.collateralPosted(user1);
		removalAttempt = bound(removalAttempt, 1, posted);

		vm.expectRevert(MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector);
		borrowableCDAI.removeCollateral(removalAttempt);
		vm.stopPrank();
	}

	function test_fuzz_RemoveCollateral_fail_whenRemovingSlightlyMoreCollateralThanRequired(uint256 initialDeposit) public {
		_setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 10_000_000e18);
		_setCTokenConfigBasic(address(borrowableCUSDC), 10_000_000e6, 10_000_000e6);

		vm.startPrank(user2);
		_prepareUSDC(user2, 10_000_000e6);
		usdc.approve(address(borrowableCUSDC), 10_000_000e6);
		borrowableCUSDC.deposit(10_000_000e6, user2);
		vm.stopPrank();

		initialDeposit = bound(initialDeposit, 1_000e18, 1_000_000e18);
		_prepareDAI(user1, initialDeposit);

		vm.startPrank(user1);
		dai.approve(address(borrowableCDAI), initialDeposit);
		borrowableCDAI.depositAsCollateral(initialDeposit, user1);
		vm.stopPrank();

        // borrow 30% LTV since both assets are the same price
		uint256 borrowAssets = ((initialDeposit * 3000) / 10000) / 1e12;

		vm.startPrank(user1);
		borrowableCUSDC.borrow(borrowAssets, user1);
		vm.stopPrank();

		skip(20 minutes);

		uint256 collRatioBps = 7000;
		uint256 debtAssets = borrowableCUSDC.debtBalance(user1);

        uint256 debtScaledToBPS = debtAssets * 10_000;
        uint256 ratioScaledToDebtAsset = collRatioBps * 1e6; // usdc 6 decimals
		uint256 minSharesNeeded = (debtScaledToBPS + ratioScaledToDebtAsset - 1) / ratioScaledToDebtAsset;

		uint256 posted = borrowableCDAI.collateralPosted(user1);

        uint256 removeCollateralAmount = posted - minSharesNeeded + 1;

		vm.startPrank(user1);
		vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
		borrowableCDAI.removeCollateral(removeCollateralAmount);
		vm.stopPrank();
	}

}