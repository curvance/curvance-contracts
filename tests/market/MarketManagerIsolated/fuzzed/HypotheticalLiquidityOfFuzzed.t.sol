// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestHypotheticalLiquidityOfFuzzed is TestBaseMarketIsolated {

	function setUp() override public {
		super.setUp();

		_prepareDAI(address(this), 77777);
		_prepareUSDC(address(this), 77777);

		dai.approve(address(borrowableCDAI), 77777);
		usdc.approve(address(borrowableCUSDC), 77777);

		marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

		_setCTokenConfigBasic(address(borrowableCDAI), 10_000_000e18, 10_000_000e18);
		_setCTokenConfigBasic(address(borrowableCUSDC), 10_000_000e6, 10_000_000e6);

		// Provide liquidity
		vm.startPrank(user2);
		_prepareUSDC(user2, 10_000_000e6);
		usdc.approve(address(borrowableCUSDC), type(uint256).max);
		borrowableCUSDC.deposit(10_000_000e6, user2);
		vm.stopPrank();
        
		mockUsdcFeed.setMockAnswer(1e8);
		mockDaiFeed.setMockAnswer(1e8);
	}

	function test_fuzz_hypotheticalLiquidityOf_positionPruning(uint256 depositDAI, uint256 borrowUSDC) public {

		depositDAI = bound(depositDAI, 1_000e18, 1_000_000e18);

		// 60% LTV upper bound (70% configured)
		uint256 maxBorrow = (depositDAI * 6000) / 10000 / 1e12; // scale to 6 decimals
		borrowUSDC = bound(borrowUSDC, 50e6, maxBorrow);

		vm.startPrank(user1);
		_prepareDAI(user1, depositDAI);
		dai.approve(address(borrowableCDAI), depositDAI);
		borrowableCDAI.depositAsCollateral(depositDAI, user1);
		borrowableCUSDC.borrow(borrowUSDC, user1);
		vm.stopPrank();

		skip(20 minutes);

		// Repay all debt + interest
		vm.startPrank(user1);
		_prepareUSDC(user1, 10_000_000e6);
		usdc.approve(address(borrowableCUSDC), type(uint256).max);
		borrowableCUSDC.repay(0);
		vm.stopPrank();

		// After full repay debt position should be stale, but still present in assets.
		address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);
		(uint256 cSurplus, uint256 lDeficit, bool[] memory toClose) =
			marketManagerIsolated.hypotheticalLiquidityOf(user1, address(borrowableCDAI), 0, 0);

		assertEq(lDeficit, 0, "liquidity should not be deficit");
		assertGt(cSurplus, 0, "liquidity should have surplus");
		assertEq(toClose.length, assetsBefore.length, "collateral position should be present");

		uint256 debtIndex = _getAssetIndexOf(assetsBefore, address(borrowableCUSDC));
		uint256 collateralIndex = _getAssetIndexOf(assetsBefore, address(borrowableCDAI));

		assertTrue(toClose[debtIndex], "stale debt position should be suggested to close");
		assertFalse(toClose[collateralIndex], "active collateral should not be suggested to close");

		// Trigger position pruning by removing a portion of collateral
		vm.prank(user1);
		borrowableCDAI.removeCollateral(depositDAI / 10);

		address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
		assertEq(assetsAfter.length, 1, "only collateral position should remain");
		assertEq(assetsAfter[0], address(borrowableCDAI), "remaining position should be collateral");

		// Collateral position should be closed if removing all collateral
		uint256 remaining = borrowableCDAI.collateralPosted(user1);

		(, , bool[] memory toClose2) =
			marketManagerIsolated.hypotheticalLiquidityOf(user1, address(borrowableCDAI), remaining, 0);

		assertEq(toClose2.length, 1, "one asset remains");
		assertTrue(toClose2[0], "full redemption should close last position");

		// Execute full collateral removal
		vm.prank(user1);
		borrowableCDAI.removeCollateral(remaining);

		// Assert all positions are cleared
		address[] memory assetsFinal = marketManagerIsolated.assetsOf(user1);
		assertEq(assetsFinal.length, 0, "all positions should be cleared");
	}

	function _getAssetIndexOf(address[] memory assetsOf, address token) internal pure returns (uint256) {
		for (uint256 i; i < assetsOf.length; ++i) {
			if (assetsOf[i] == token) return i;
		}
		revert("asset not found");
	}
}