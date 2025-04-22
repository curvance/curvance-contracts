// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManager } from "tests/market/marketManager/TestBaseMarketManager.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
contract AtlasParametersTest is TestBaseMarketManager {
    address dappControlUser = makeAddr("dappControlUser");


    function setUp() public override {
        super.setUp();
        
        // Setup market with tokens
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETHIsolated), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDCIsolated), 42069);
        
        // List tokens in the market
        marketManagerIsolated.listTokens(address(pBALRETHIsolated), address(eUSDCIsolated));
        
        // Set position token parameters
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );

        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        marketManagerIsolated.addAuthorizedAtlasDAppControl(dappControlUser);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETHIsolated);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setPTokenCollateralCaps(tokens, caps);

    }

    function testSetAtlasParameters() public {
        // Only dapp control can set penalty
        vm.startPrank(dappControlUser);
        
        // Set a valid penalty (WAD + 15%)
        uint256 validPenalty = 1.15e18;
        uint256 closeFactor = 0.30e18;
        marketManagerIsolated.setAtlasParameters(validPenalty, closeFactor);

        // Verify the penalty was set correctly
        assertEq(marketManagerIsolated.getLatestPenalty(), validPenalty);
        assertEq(marketManagerIsolated.getLatestCloseFactor(), closeFactor);
        vm.stopPrank();
    }
    
    function testSetAtlasParametersUnauthorized() public {
        // // Non-dapp control user should not be able to set penalty
        vm.startPrank(user1);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setAtlasParameters(1.15e18, 1.30e18);
        
        vm.stopPrank();
    }
    
    function testSetAtlasParametersInvalidValue() public {
        vm.startPrank(dappControlUser);
        
        uint256 tooLowPenalty = 1.01e18;
        uint256 tooHighPenalty = 1.25e18; 
        uint256 validPenalty = 1.15e18;
        uint256 tooHighCloseFactor = 1.51e18;
        uint256 tooLowCloseFactor = 1.09e18;
        uint256 validCloseFactor = 1.30e18;

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAtlasParameters(tooLowPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAtlasParameters(tooHighPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAtlasParameters(validPenalty, tooHighCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setAtlasParameters(validPenalty, tooLowCloseFactor);

        vm.stopPrank();
    }
    
    function testResetAtlasParameters() public {
        vm.startPrank(dappControlUser);
        
        uint256 validPenalty = 1.15e18;
        uint256 validCloseFactor = 0.30e18;
        marketManagerIsolated.setAtlasParameters(validPenalty, validCloseFactor);
        assertEq(marketManagerIsolated.getLatestPenalty(), validPenalty);
        assertEq(marketManagerIsolated.getLatestCloseFactor(), validCloseFactor);
        
        marketManagerIsolated.resetAtlasParameters();
        
        uint256 defaultPenalty = 1.10e18; // 10% as set in setUp
        assertEq(marketManagerIsolated.getLatestPenalty(), defaultPenalty);
        assertEq(marketManagerIsolated.getLatestCloseFactor(), 0);
        
        vm.stopPrank();
    }

    function testResetPenaltyUnauthorized() public {
        vm.startPrank(user1);
        
        vm.expectRevert();
        marketManagerIsolated.resetAtlasParameters();
        
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

        uint256 incentive = 1.20e18; 
        uint256 earnTokenPrice = 2e18; 
        uint256 pTokenPrice = 1677420866257185401796; 
        uint256 exchangeRate = 1e18;  
        
        uint256 debtToCollateralRatio = (incentive * earnTokenPrice * WAD) /
            (pTokenPrice * exchangeRate);
        
        uint256 amountAdjusted = (250000000 * 10**18) / 10**6;
        
        uint256 liquidatedTokens = (amountAdjusted * debtToCollateralRatio) / WAD;
        
        return liquidatedTokens;
    }

    function testLiquidationWithDynamicPenalty() public {
        _prepareLiquidationIsolated();

        testSetAtlasParameters();

        _prepareUSDC(user3, 250e6);

        vm.startPrank(user3);

        usdc.approve(address(eUSDCIsolated), 250e6);
        eUSDCIsolated.liquidateExact(user1, 250e6, address(pBALRETHIsolated));
        vm.stopPrank();

        uint256 liquidatorpTokenBalance = pBALRETHIsolated.balanceOf(user3);
        assertEq(liquidatorpTokenBalance, _calculateExpectedLiquidatedTokensWithDynamicPenalty());

        uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
        assertEq(liquidatorUSDCBalance, 0);

    }

    function _calculateExpectedLiquidatedTokensWithDefaultPenalty() public pure returns (uint256) {
        uint256 WAD = 1e18;

        uint256 incentive = 1.10e18; // Default 10% penalty
        uint256 earnTokenPrice = 2e18; 
        uint256 pTokenPrice = 1677420866257185401796; 
        uint256 exchangeRate = 1e18;  
        
        uint256 debtToCollateralRatio = (incentive * earnTokenPrice * WAD) /
            (pTokenPrice * exchangeRate);
        
        uint256 amountAdjusted = (250000000 * 10**18) / 10**6;
        
        uint256 liquidatedTokens = (amountAdjusted * debtToCollateralRatio) / WAD;
        
        return liquidatedTokens;
    }

    function testLiquidationWithDefaultPenalty() public {
        _prepareLiquidationIsolated();

        _prepareUSDC(user3, 250e6);

        vm.startPrank(user3);

        usdc.approve(address(eUSDCIsolated), 250e6);
        eUSDCIsolated.liquidateExact(user1, 250e6, address(pBALRETHIsolated));
        vm.stopPrank();

        uint256 liquidatorpTokenBalance = pBALRETHIsolated.balanceOf(user3);
        assertEq(liquidatorpTokenBalance, _calculateExpectedLiquidatedTokensWithDefaultPenalty());

        uint256 liquidatorUSDCBalance = usdc.balanceOf(user3);
        assertEq(liquidatorUSDCBalance, 0);
    }
}