// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { console2 } from "forge-std/console2.sol";


contract AtlasParametersTest is TestBaseMarketManagerIsolated {
    address dappControlUser = makeAddr("dappControlUser");


    function setUp() public override {
        super.setUp();

    }

    function testSetAuctionParameters() public {
        _setUpMarketNonLiquidation();
        // Only dapp control can set penalty
        vm.startPrank(dappControlUser);
        
        // Set a valid penalty (WAD + 15%)
        uint256 validPenalty = 1.15e18;
        uint256 closeFactor = 0.30e18;
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), validPenalty, closeFactor);

        // Verify the penalty was set correctly
        (uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getLatestAuctionParameters();
        assertEq(currentPenalty, validPenalty);
        assertEq(currentCloseFactor, closeFactor);
        vm.stopPrank();
    }
    
    function testSetAuctionParametersUnauthorized() public {
        _setUpMarketNonLiquidation();

        // // Non-dapp control user should not be able to set penalty
        vm.startPrank(user1);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), 1.15e18, 0.30e18);
        
        vm.stopPrank();
    }
    
    function testSetAuctionParametersInvalidValue() public {
        _setUpMarketNonLiquidation();
        
        vm.startPrank(dappControlUser);
        
        uint256 tooLowPenalty = 1.01e18;
        uint256 tooHighPenalty = 1.25e18; 
        uint256 validPenalty = 1.15e18;
        uint256 tooHighCloseFactor = 1.51e18;
        uint256 tooLowCloseFactor = 1.09e18;
        uint256 validCloseFactor = 0.30e18;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), tooLowPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), tooHighPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), validPenalty, tooHighCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), validPenalty, tooLowCloseFactor);

        vm.stopPrank();
    }
    
    function testResetAuctionParameters() public {
        _setUpMarketNonLiquidation();

        vm.startPrank(dappControlUser);
        
        uint256 validPenalty = 1.15e18;
        uint256 validCloseFactor = 0.30e18;
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), validPenalty, validCloseFactor);

        (uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getLatestAuctionParameters();
        assertEq(currentPenalty, validPenalty);
        assertEq(currentCloseFactor, validCloseFactor);
        
        marketManagerIsolated.resetAuctionParameters();
        
        // uint256 defaultPenalty = 1.10e18; // Not used anymore because getLatestAuctionParameters does not return default penalties anymore.
        (currentPenalty, currentCloseFactor) = marketManagerIsolated.getLatestAuctionParameters();
        assertEq(currentPenalty, 0);
        assertEq(currentCloseFactor, 0);
        
        vm.stopPrank();
    }

    function testResetAuctionParametersUnauthorized() public {
        _setUpMarketNonLiquidation();

        vm.startPrank(user1);
        
        vm.expectRevert();
        marketManagerIsolated.resetAuctionParameters();
        
        vm.stopPrank();
    }

    // in _canLiquidate:
    // cFactor = 200000000000000000 (baseCFactor) + 
    // ((800000000000000000 (cFactorCurve) * 1000000000000000000 (lFactor)) / WAD)
    // pass incentive == 0
    // maxAmount = 1000000762
    // debtToCollateralRatio =
    // (1.20e18 (incentive 20%) *  2000000000000000000 (data.debtTokenPrice) * WAD) /
    // (1677420866257185401796 (data.collateralTokenPrice) * 1000000000000000000 (data.exchangeRate))

    // amountAdjusted = 250000000 (debtamount) * 1e18 / 1e6  // convert from USDC 6 decimals to 18 decimals
    
    // collateralLiquidated = amountAdjusted * debtToCollateralRatio / WAD
    function _calculateExpectedLiquidatedTokensWithDynamicPenaltyAndLiquidate() public view returns (uint256) {
        uint256 WAD_SQUARED = 1e36;

        uint256 incentive = 1.15e18; 
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
        
        uint256 debtToCollateralMultiplier = (((incentive * debtTokenPrice * WAD_SQUARED) /
            (cTokenPrice * exchangeRate)) * collateralDecimals) / debtDecimals;
        
        uint256 collateralLiquidated = (debtAmount * debtToCollateralMultiplier) / WAD_SQUARED;
        
        return collateralLiquidated;
    }

    function testLiquidateExactWithDynamicPenalty() public {
        _prepareLiquidation();

        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();

        _prepareUSDC(user3, 250e6);

        vm.startPrank(dappControlUser);

        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));
        
        // Set auction parameters
        uint256 validPenalty = 1.15e18;
        uint256 closeFactor = 0.30e18;
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), validPenalty, closeFactor);
        
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
        assertEq(liquidatorcTokenBalance, _calculateExpectedLiquidatedTokensWithDynamicPenaltyAndLiquidate(), 
        "Liquidator cToken balance should match expected");

        uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
        assertEq(liquidatorUSDCBalance, 0, "Liquidator USDC balance should be 0");
    }

    function _calculateExpectedLiquidatedTokensWithDefaultPenalty() public view returns (uint256) {
        uint256 WAD = 1e18;
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
        
        uint256 liqBaseIncentive = 1.1e18;
        uint256 liqCurve = 5e16;
        
        uint256 incentive = liqBaseIncentive + ((liqCurve * lFactor) / WAD);
        
        uint256 collateralDecimals = 10**18;
        uint256 debtDecimals = 10**6;
        uint256 debtAmount = 250e6;
        
        uint256 debtToCollateralMultiplier = (((incentive * debtTokenPrice * WAD_SQUARED) /
            (cTokenPrice * exchangeRate)) * collateralDecimals) / debtDecimals;
        
        uint256 collateralLiquidated = (debtAmount * debtToCollateralMultiplier) / WAD_SQUARED;
        
        return collateralLiquidated;
    }

    function testLiquidationWithDefaultPenalty() public {
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

    function testLiquidationFailureWithDifferentUnlockedCollateral() public {
        _prepareLiquidation();

        _prepareUSDC(user3, 250e6);

        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();

        vm.prank(dappControlUser);
        marketManagerIsolated.unlockAuctionCollateral(address(1));

        address[] memory usersToLiquidate = new address[](1);   
        usersToLiquidate[0] = user1;
        uint256[] memory amountsToLiquidate = new uint256[](1);
        amountsToLiquidate[0] = 250e6;

        vm.startPrank(user3);

        usdc.approve(address(borrowableCUSDC), 250e6);
        vm.expectRevert(MarketManagerIsolated.MarketManager__UnauthorizedCollateral.selector);
        borrowableCUSDC.liquidateExact(amountsToLiquidate, usersToLiquidate, address(strategyCBALRETH));
        vm.stopPrank();
    }

    function testLiquidateWithDynamicPenalty() public {
        _prepareLiquidation();

        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();

        // Set a valid penalty (WAD + 15%)
        vm.startPrank(dappControlUser);
        marketManagerIsolated.unlockAuctionCollateral(address(strategyCBALRETH));
        uint256 validPenalty = 1.15e18; //15%
        uint256 closeFactor = 0.30e18; // 30%
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), validPenalty, closeFactor);
        vm.stopPrank();

        borrowableCUSDC.accrueIfNeeded(); // pull interest forward
        uint256 debtBalance = IBorrowableCToken(address(borrowableCUSDC)).debtBalance(user1);

        uint256 closeBalance = (debtBalance * 0.30e18) / 1e18;

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

    function _setUpMarketNonLiquidation() internal {
        // Setup market with tokens
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // List tokens in the market
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
        
        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();
    }
}