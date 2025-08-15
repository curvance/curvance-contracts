// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { WAD, WAD_CUBED_BPS_OFFSET,BPS } from "contracts/libraries/ConstantsLib.sol";

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

        vm.startPrank(dappControlUser);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));
        
        // Set auction parameters
        uint256 validPenalty = 11500;
        uint256 closeFactor = 3000;
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), validPenalty, closeFactor);
        
        vm.stopPrank();
        
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

        vm.startPrank(dappControlUser);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));

        vm.stopPrank();

        (, uint256 cTokenPrice, ) = marketManagerIsolated.liquidationStatusOf(
            user1,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );
        
        (uint256 lFactor,,) = marketManagerIsolated.liquidationStatusOf(
            user1,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );
        
        uint256 liqBaseIncentive = 11000;
        uint256 liqCurve = 500;
        
        uint256 incentive = liqBaseIncentive + ((liqCurve * lFactor) / WAD);
        
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

        vm.startPrank(dappControlUser);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        marketManagerIsolated.unlockAuctionCollateral(address(1));
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

        vm.prank(dappControlUser);
        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));

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
        vm.startPrank(dappControlUser);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));
        uint256 validPenalty = 11500; //15%
        uint256 closeFactor = 3000; // 30%
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), validPenalty, closeFactor);
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

    function _calculateExpectedLiquidatedTokensWithDefaultPenalty() internal view returns (uint256) {
        uint256 WAD_SQUARED = 1e36;

        uint256 debtTokenPrice = 2e18; 
        uint256 cTokenPrice;
        uint256 exchangeRate = strategyCBALRETH.exchangeRate();

        (, cTokenPrice, ) = marketManagerIsolated.liquidationStatusOf(
            user1,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );

        (uint256 lFactor,,) = marketManagerIsolated.liquidationStatusOf(
            user1,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );

        uint256 liqBaseIncentive = 11000; // 10% base, premium BPS
        uint256 liqCurve = 500; // 5% curve, in BPS

        uint256 incentive = liqBaseIncentive + ((liqCurve * lFactor) / WAD);

        uint256 collateralDecimals = 10**18;
        uint256 debtDecimals = 10**6;
        uint256 debtAmount = 250e6;

        uint256 debtToCollateralMultiplier = (((incentive * debtTokenPrice * WAD_CUBED_BPS_OFFSET) /
            (cTokenPrice * exchangeRate)) * collateralDecimals) / debtDecimals;

        uint256 collateralLiquidated = (debtAmount * debtToCollateralMultiplier) / WAD_SQUARED;

        return collateralLiquidated;
    }

    function _calculateExpectedLiquidatedTokens(uint256 incentive) internal view returns (uint256) {
        // in _canLiquidate:
        // cFactor = 200000000000000000 (closeFactorBase) + 
        // ((800000000000000000 (closeFactorCurve) * 1000000000000000000 (lFactor)) / WAD)
        // maxAmount = 1000000762
        // debtToCollateralRatio =
        // `incentive` *  2000000000000000000 (data.debtTokenPrice) * WAD) /
        // (1677420866257185401796 (data.collateralTokenPrice) * 1000000000000000000 (data.exchangeRate))
        // amountAdjusted = 250000000 (debtAmount) * 1e18 / 1e6  // convert from USDC 6 decimals to 18 decimals
        // collateralLiquidated = amountAdjusted * debtToCollateralRatio / WAD

        uint256 WAD_SQUARED = 1e36;
        uint256 debtTokenPrice = 2e18; 
        uint256 cTokenPrice;
        uint256 exchangeRate = strategyCBALRETH.exchangeRate();
        
        (, cTokenPrice, ) = marketManagerIsolated.liquidationStatusOf(
            user1,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );
        
        uint256 collateralDecimals = 10**18;
        uint256 debtDecimals = 10**6;
        uint256 debtAmount = 250e6;
        
        uint256 debtToCollateralMultiplier = (((incentive * debtTokenPrice * WAD_CUBED_BPS_OFFSET) /
            (cTokenPrice * exchangeRate)) * collateralDecimals) / debtDecimals;
        
        uint256 collateralLiquidated = (debtAmount * debtToCollateralMultiplier) / WAD_SQUARED;
        
        return collateralLiquidated;
    }
}