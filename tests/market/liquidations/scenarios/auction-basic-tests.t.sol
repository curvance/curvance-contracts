// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { WAD, WAD_SQUARED_BPS_OFFSET, BPS } from "contracts/libraries/ConstantsLib.sol";

import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { console2 } from "forge-std/console2.sol";

contract AuctionBasicTests is TestBaseLiquidations {

    function setUp() public override {
        super.setUp();
    }

    function test_success_LiquidateExactWithAuctionAndDynamicPenalty() public {
        _prepareLiquidation();
        _prepareUSDC(user3, 250e6);
        _setAuctionConfigs(address(strategyCBALRETH), 11500, 3000);
        
        vm.startPrank(user3);
        address[] memory usersToLiquidate = new address[](1);   
        usersToLiquidate[0] = user1;
        uint256[] memory amountsToLiquidate = new uint256[](1);
        amountsToLiquidate[0] = 250e6;

        usdc.approve(address(borrowableCUSDC), 250e6);
        borrowableCUSDC.liquidateExact(amountsToLiquidate, usersToLiquidate, address(strategyCBALRETH));
        vm.stopPrank();

        console2.log("done liquidating");

        uint256 liquidatorcTokenBalance = strategyCBALRETH.balanceOf(user3);
        assertEq(liquidatorcTokenBalance, _calculateExpectedLiquidatedTokens(11500), 
        "Liquidator cToken balance should match expected");

        uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
        assertEq(liquidatorUSDCBalance, 0, "Liquidator USDC balance should be 0");
    }

    function test_success_LiquidateExactWithAuctionAndDefaultPenalty() public {
        _prepareLiquidation();
        _prepareUSDC(user3, 250e6);

        // Override closeFactorMax to 100% close factor so we can pass default
        // penalty based on lFactor.
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 10;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 10000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);
        
        (uint256 cTokenPrice,) = oracleManager.getPriceIsolatedPair(address(strategyCBALRETH), address(borrowableCUSDC), 2);
        
        (, , , uint256 lFactor) = _liquidationValuesOfHelper(marketManagerIsolated, user1);
        
        // Calculate default penalty and close factor.
        uint256 liqIncBase = 11000;
        uint256 liqCurve = 500;
        uint256 incentive = liqIncBase + ((liqCurve * lFactor) / WAD);

        uint256 closeFactorBase = 2000;
        uint256 closeFactorCurve = 8000;
        uint256 closeFactor = closeFactorBase + ((closeFactorCurve * lFactor) / WAD);

        _setAuctionConfigs(address(strategyCBALRETH), incentive, closeFactor);
        
        vm.startPrank(user3);
        address[] memory usersToLiquidate = new address[](1);   
        usersToLiquidate[0] = user1;
        uint256[] memory amountsToLiquidate = new uint256[](1);
        amountsToLiquidate[0] = 250e6;

        usdc.approve(address(borrowableCUSDC), 250e6);
        borrowableCUSDC.liquidateExact(amountsToLiquidate, usersToLiquidate, address(strategyCBALRETH));
        vm.stopPrank();

        console2.log("done liquidating");

        uint256 liquidatorcTokenBalance = strategyCBALRETH.balanceOf(user3);
        assertEq(liquidatorcTokenBalance, _calculateExpectedLiquidatedTokens(incentive), 
        "Liquidator cToken balance should match expected");

        uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
        assertEq(liquidatorUSDCBalance, 0, "Liquidator USDC balance should be 0");
    }

    function test_success_LiquidationWithDefaultPenalty() public {
        _prepareLiquidation();
        _prepareUSDC(user3, 250e6);

        vm.startPrank(user3);

        address[] memory usersToLiquidate = new address[](1);   
        usersToLiquidate[0] = user1;
        uint256[] memory amountsToLiquidate = new uint256[](1);
        amountsToLiquidate[0] = 250e6;

        usdc.approve(address(borrowableCUSDC), 250e6);
        borrowableCUSDC.liquidateExact(amountsToLiquidate, usersToLiquidate, address(strategyCBALRETH));
        vm.stopPrank();

        uint256 liquidatorcTokenBalance = strategyCBALRETH.balanceOf(user3);
        assertEq(liquidatorcTokenBalance, _calculateExpectedLiquidatedTokensWithDefaultPenalty());

        uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
        assertEq(liquidatorUSDCBalance, 0);
    }

    function test_fail_LiquidationWithDifferentUnlockedCollateral() public {
        _prepareLiquidation();
        _prepareUSDC(user3, 250e6);

        vm.startPrank(auctionPermsUser);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        // We unlock borrowableCUSDC when we will try to liquidate strategyCBALRETH.
        marketManagerIsolated.setTransientLiquidationConfig(
            address(borrowableCUSDC),
            11500,
            3000
        );

        vm.stopPrank();

        address[] memory usersToLiquidate = new address[](1);   
        usersToLiquidate[0] = user1;
        uint256[] memory amountsToLiquidate = new uint256[](1);
        amountsToLiquidate[0] = 250e6;

        vm.startPrank(user3);

        usdc.approve(address(borrowableCUSDC), 250e6);
        vm.expectRevert(MarketManagerIsolated.MarketManager__UnauthorizedLiquidation.selector);
        borrowableCUSDC.liquidateExact(amountsToLiquidate, usersToLiquidate, address(strategyCBALRETH));
        vm.stopPrank();
    }

    function test_fail_LiquidationWithMarketLocked() public {
        _prepareLiquidation();
        _prepareUSDC(user3, 250e6);

        vm.startPrank(auctionPermsUser);

        marketManagerIsolated.setTransientLiquidationConfig(
            address(strategyCBALRETH),
            11500,
            3000
        );

        vm.stopPrank();

        address[] memory usersToLiquidate = new address[](1);   
        usersToLiquidate[0] = user1;
        uint256[] memory amountsToLiquidate = new uint256[](1);
        amountsToLiquidate[0] = 250e6;

        vm.startPrank(user3);

        usdc.approve(address(borrowableCUSDC), 250e6);
        vm.expectRevert(MarketManagerIsolated.MarketManager__UnauthorizedLiquidation.selector);
        borrowableCUSDC.liquidateExact(amountsToLiquidate, usersToLiquidate, address(strategyCBALRETH));
        vm.stopPrank();
    }

    function test_success_LiquidateWithDynamicPenalty() public {
        _prepareLiquidation();

        // Set a valid penalty (WAD + 15%)
        vm.startPrank(auctionPermsUser);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        
        uint256 validPenalty = 11500; //15%
        uint256 closeFactor = 3000; // 30%
        marketManagerIsolated.setTransientLiquidationConfig(address(strategyCBALRETH), validPenalty, closeFactor);
        vm.stopPrank();

        borrowableCUSDC.accrueIfNeeded(); // pull interest forward
        uint256 debtBalance = IBorrowableCToken(address(borrowableCUSDC)).debtBalance(user1);

        uint256 closeBalance = (debtBalance * 3000) / 10000;

        _prepareUSDC(user3, debtBalance);

        ExpectedLiquidationValues memory expectedLiquidationValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: true,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        vm.startPrank(user3);

        address[] memory usersToLiquidate = new address[](1);   
        usersToLiquidate[0] = user1;
        uint256[] memory amountsToLiquidate = new uint256[](1);
        amountsToLiquidate[0] = debtBalance;

        usdc.approve(address(borrowableCUSDC), debtBalance);
        borrowableCUSDC.liquidate(usersToLiquidate, address(strategyCBALRETH));
        vm.stopPrank();

        uint256 liquidatorcTokenBalance = strategyCBALRETH.balanceOf(user3);
        assertEq(liquidatorcTokenBalance, expectedLiquidationValues.collateralLiquidated);

        uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
        assertEq(liquidatorUSDCBalance, debtBalance - closeBalance);
    }

    function _calculateExpectedLiquidatedTokensWithDefaultPenalty() internal returns (uint256) {
        uint256 WAD_SQUARED = 1e36;

        uint256 debtTokenPrice; 
        uint256 cTokenPrice;

        (cTokenPrice, debtTokenPrice) = oracleManager.getPriceIsolatedPair(address(strategyCBALRETH), address(borrowableCUSDC), 2);

        (, , , uint256 lFactor) = _liquidationValuesOfHelper(marketManagerIsolated, user1);

        uint256 liqBaseIncentive = 11000; // 10% base, premium BPS
        uint256 liqCurve = 500; // 5% curve, in BPS

        uint256 incentive = liqBaseIncentive + ((liqCurve * lFactor) / WAD);

        uint256 collateralDecimals = 10**18;
        uint256 debtDecimals = 10**6;
        uint256 debtAmount = 250e6;

        uint256 debtToCollateralMultiplier =
            (((incentive * debtTokenPrice * WAD_SQUARED_BPS_OFFSET) /
                cTokenPrice) * collateralDecimals) / debtDecimals;

        uint256 collateralLiquidated = (debtAmount * debtToCollateralMultiplier) / WAD_SQUARED;

        return collateralLiquidated;
    }

    function _calculateExpectedLiquidatedTokens(uint256 incentive) internal returns (uint256) {

        uint256 WAD_SQUARED = 1e36;
        uint256 debtTokenPrice; 
        uint256 cTokenPrice;
        
        (cTokenPrice, debtTokenPrice) = oracleManager.getPriceIsolatedPair(address(strategyCBALRETH), address(borrowableCUSDC), 2);
        
        uint256 collateralDecimals = 10**18;
        uint256 debtDecimals = 10**6;
        uint256 debtAmount = 250e6;
        
        uint256 debtToCollateralMultiplier =
            (((incentive * debtTokenPrice * WAD_SQUARED_BPS_OFFSET) /
                cTokenPrice) * collateralDecimals) / debtDecimals;
        
        uint256 collateralLiquidated = (debtAmount * debtToCollateralMultiplier) / WAD_SQUARED;
        
        return collateralLiquidated;
    }
}