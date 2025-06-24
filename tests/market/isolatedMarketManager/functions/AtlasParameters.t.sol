// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

contract AtlasParametersTest is TestBaseMarketManagerIsolated {
    address dappControlUser = makeAddr("dappControlUser");


    function setUp() public override {
        super.setUp();

    }

    function testsetAuctionParameters() public {
        _setUpMarketNonLiquidation();
        // Only dapp control can set penalty
        vm.startPrank(dappControlUser);
        
        // Set a valid penalty (WAD + 15%)
        uint256 validPenalty = 1.15e18;
        uint256 closeFactor = 0.30e18;
        marketManagerIsolated.setAuctionParameters(validPenalty, closeFactor);

        // Verify the penalty was set correctly
        (uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getLatestAuctionParameters();
        assertEq(currentPenalty, validPenalty);
        assertEq(currentCloseFactor, closeFactor);
        vm.stopPrank();
    }
    
    function testsetAuctionParametersUnauthorized() public {
        _setUpMarketNonLiquidation();

        // // Non-dapp control user should not be able to set penalty
        vm.startPrank(user1);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setAuctionParameters(1.15e18, 0.30e18);
        
        vm.stopPrank();
    }
    
    function testsetAuctionParametersInvalidValue() public {
        _setUpMarketNonLiquidation();
        
        vm.startPrank(dappControlUser);
        
        uint256 tooLowPenalty = 1.01e18;
        uint256 tooHighPenalty = 1.25e18; 
        uint256 validPenalty = 1.15e18;
        uint256 tooHighCloseFactor = 1.51e18;
        uint256 tooLowCloseFactor = 1.09e18;
        uint256 validCloseFactor = 0.30e18;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAuctionParameters(tooLowPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAuctionParameters(tooHighPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAuctionParameters(validPenalty, tooHighCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAuctionParameters(validPenalty, tooLowCloseFactor);

        vm.stopPrank();
    }
    
    function testResetAuctionParameters() public {
        _setUpMarketNonLiquidation();

        vm.startPrank(dappControlUser);
        
        uint256 validPenalty = 1.15e18;
        uint256 validCloseFactor = 0.30e18;
        marketManagerIsolated.setAuctionParameters(validPenalty, validCloseFactor);

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
    // (1.20e18 (incentive 20%) *  2000000000000000000 (data.earnTokenPrice) * WAD) /
    // (1677420866257185401796 (data.positionTokenPrice) * 1000000000000000000 (data.exchangeRate))

    // amountAdjusted = 250000000 (debtamount) * 1e18 / 1e6  // convert from USDC 6 decimals to 18 decimals
    
    // liquidatedTokens = amountAdjusted * debtToCollateralRatio / WAD
    function _calculateExpectedLiquidatedTokensWithDynamicPenalty() public pure returns (uint256) {
        uint256 WAD = 1e18;

        uint256 incentive = 1.15e18; 
        uint256 earnTokenPrice = 2e18; 
        uint256 cTokenPrice = 1677420866257185401796; 
        uint256 exchangeRate = 1e18;  
        
        uint256 debtToCollateralRatio = (incentive * earnTokenPrice * WAD) /
            (cTokenPrice * exchangeRate);
        
        uint256 amountAdjusted = (250000000 * 10**18) / 10**6;
        
        uint256 liquidatedTokens = (amountAdjusted * debtToCollateralRatio) / WAD;
        
        return liquidatedTokens;
    }

    // function testLiquidationWithDynamicPenalty() public {
    //     _prepareLiquidationIsolated();

    //     testsetAuctionParameters();

    //     _prepareUSDC(user3, 250e6);
    //     vm.startPrank(user3);

    //     address[] memory usersToLiquidate = new address[](1);   
    //     usersToLiquidate[0] = user1;
    //     uint256[] memory amountsToLiquidate = new uint256[](1);
    //     amountsToLiquidate[0] = 250e6;

    //     usdc.approve(address(eUSDC), 250e6);
    //     eUSDC.liquidateExact(usersToLiquidate, amountsToLiquidate, address(pBALRETH));
    //     vm.stopPrank();

    //     uint256 liquidatorcTokenBalance = pBALRETH.balanceOf(user3);
    //     assertEq(liquidatorcTokenBalance, _calculateExpectedLiquidatedTokensWithDynamicPenalty());

    //     uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
    //     assertEq(liquidatorUSDCBalance, 0);

    // }

    function _calculateExpectedLiquidatedTokensWithDefaultPenalty() public pure returns (uint256) {
        uint256 WAD = 1e18;

        uint256 incentive = 1.10e18; // Default 10% penalty
        uint256 earnTokenPrice = 2e18; 
        uint256 cTokenPrice = 1677420866257185401796; 
        uint256 exchangeRate = 1e18;  
        
        uint256 debtToCollateralRatio = (incentive * earnTokenPrice * WAD) /
            (cTokenPrice * exchangeRate);
        
        uint256 amountAdjusted = (250000000 * 10**18) / 10**6;
        
        uint256 liquidatedTokens = (amountAdjusted * debtToCollateralRatio) / WAD;
        
        return liquidatedTokens;
    }

    // function testLiquidationWithDefaultPenalty() public {
    //     _prepareLiquidationIsolated();

    //     _prepareUSDC(user3, 250e6);

    //     vm.startPrank(user3);

    //     address[] memory usersToLiquidate = new address[](1);   
    //     usersToLiquidate[0] = user1;
    //     uint256[] memory amountsToLiquidate = new uint256[](1);
    //     amountsToLiquidate[0] = 250e6;

    //     usdc.approve(address(eUSDC), 250e6);
    //     eUSDC.liquidateExact(usersToLiquidate, amountsToLiquidate, address(pBALRETH));
    //     vm.stopPrank();

    //     uint256 liquidatorcTokenBalance = pBALRETH.balanceOf(user3);
    //     assertEq(liquidatorcTokenBalance, _calculateExpectedLiquidatedTokensWithDefaultPenalty());

    //     uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
    //     assertEq(liquidatorUSDCBalance, 0);
    // }

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

        usdc.approve(address(eUSDC), 250e6);
        vm.expectRevert(MarketManagerIsolated.MarketManager__UnauthorizedCollateral.selector);
        eUSDC.liquidateExact(usersToLiquidate, amountsToLiquidate, address(pBALRETH));
        vm.stopPrank();
    }

    function testLiquidationWithDynamicPenaltyAndCloseFactor() public {
        _prepareLiquidation();

        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();

        // Set a valid penalty (WAD + 15%)
        vm.startPrank(dappControlUser);
        marketManagerIsolated.unlockAuctionCollateral(address(eUSDC));
        uint256 validPenalty = 1.15e18; //15%
        uint256 closeFactor = 0.30e18; // 30%
        marketManagerIsolated.setAuctionParameters(validPenalty, closeFactor);
        vm.stopPrank();

        eUSDC.accrueInterest(); // pull interest forward
        uint256 debtBalance = IBorrowableCToken(address(eUSDC)).debtBalanceCached(user1);

        uint256 closeBalance = (debtBalance * 0.30e18) / 1e18;

        _prepareUSDC(user3, debtBalance);
        vm.startPrank(user3);

        address[] memory usersToLiquidate = new address[](1);   
        usersToLiquidate[0] = user1;
        uint256[] memory amountsToLiquidate = new uint256[](1);
        amountsToLiquidate[0] = debtBalance;

        usdc.approve(address(eUSDC), debtBalance);
        eUSDC.liquidate(usersToLiquidate, address(pBALRETH));
        vm.stopPrank();

        // uint256 liquidatorcTokenBalance = pBALRETH.balanceOf(user3);
        // assertEq(liquidatorcTokenBalance, _calculateExpectedLiquidatedTokensWithDynamicPenaltyAndCloseFactor(debtBalance));

        // uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
        // assertEq(liquidatorUSDCBalance, debtBalance - closeBalance);
    }

    function _calculateExpectedLiquidatedTokensWithDynamicPenaltyAndCloseFactor(uint256 debtBalance) public pure returns (uint256) {
        uint256 WAD = 1e18;

        uint256 incentive = 1.15e18; 
        uint256 earnTokenPrice = 2e18; 
        uint256 cTokenPrice = 1677420866257185401796; 
        uint256 exchangeRate = 1e18;
        uint256 closeFactor = 1e18;
        
        uint256 debtToCollateralRatio = (incentive * earnTokenPrice * WAD) /
            (cTokenPrice * exchangeRate);
        
        uint256 maxAmount = (closeFactor * debtBalance) / WAD;
        uint256 amountAdjusted = (maxAmount * 10**18) / 10**6;
        
        uint256 liquidatedTokens = (amountAdjusted * debtToCollateralRatio) / WAD;

        return liquidatedTokens;
    }

    function _setUpMarketNonLiquidation() internal {
        // Setup market with tokens
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(pBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(eUSDC), 77777);
        
        // List tokens in the market
        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));
        
        // Set position token parameters
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);
    }
}