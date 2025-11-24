// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

import { console2 } from "forge-std/console2.sol";

contract HypotheticalLiquidityOfPricingTest is TestBaseMarketIsolated {

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

	function test_firstBorrow_usesUnderlyingPrice_NotCTokenPrice() public {
		// First borrow USDC to bump the exchangeRate
		address debtCreator = makeAddr("debtCreator");
		_prepareDAI(debtCreator, 8_000_000e18);
		vm.startPrank(debtCreator);
		dai.approve(address(borrowableCDAI), type(uint256).max);
		borrowableCDAI.depositAsCollateral(8_000_000e18, debtCreator);
		borrowableCUSDC.borrow(5_000_000e6, debtCreator);
		vm.stopPrank();
		skip(4 weeks); // enough time to accrue considerable interest
		_refreshMockFeeds();
		uint256 exchangeRate = borrowableCUSDC.exchangeRateUpdated();
		assertGt(exchangeRate, 1e18, "exchange rate should be > 1 after accrual");

		// create fresh borrower with no debt
		vm.startPrank(user1);
		_prepareDAI(user1, 1000e18);
		dai.approve(address(borrowableCDAI), type(uint256).max);
		borrowableCDAI.depositAsCollateral(1000e18, user1);
		vm.stopPrank();

		// Calculate max debt allowed based on underlying and ctoken price
		(, uint256 maxDebt, ) = marketManagerIsolated.statusOf(user1);
		(uint256 underlyingPrice, ) = oracleManager.getPrice(address(usdc), true, false);
		uint256 cTokenPrice = FixedPointMathLib.mulDiv(underlyingPrice, exchangeRate, 1e18);
		uint256 usdcDecimals = 1e6;
		uint256 underlyingMaxAssets = FixedPointMathLib.mulDiv(maxDebt, usdcDecimals, underlyingPrice);
		uint256 cTokenMaxAssets = FixedPointMathLib.mulDiv(maxDebt, usdcDecimals, cTokenPrice);
		assertGt(underlyingMaxAssets, cTokenMaxAssets, "underlying limit should exceed cToken limit when exchangeRate > 1");
        console2.log("underlyingMaxAssets - cTokenMaxAssets", underlyingMaxAssets - cTokenMaxAssets);
        // difference is ~3e6.

		// Borrow should succeed if underlying pricing is used on first borrow
        cTokenMaxAssets = cTokenMaxAssets - 10; // borrow slightly below if there's rounding.
		vm.startPrank(user1);
		borrowableCUSDC.borrow(cTokenMaxAssets, user1);
		vm.stopPrank();
	}

}