// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManager } from "tests/market/marketManager/TestBaseMarketManager.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract DynamicPenaltyTest is TestBaseMarketManager {
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
            2000     // baseCFactor 20%
        );

        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuthorizedAtlasDAppControl(dappControlUser);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETHIsolated);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setPTokenCollateralCaps(tokens, caps);

    }

    function testSetPenalty() public {
        // Only dapp control can set penalty
        vm.startPrank(dappControlUser);
        
        // Set a valid penalty (WAD + 15%)
        uint256 validPenalty = 1.15e18;
        marketManagerIsolated.setPenalty(validPenalty);
        
        // Verify the penalty was set correctly
        assertEq(marketManagerIsolated.getLatestPenalty(), validPenalty);
        
        vm.stopPrank();
    }
    
    function testSetPenaltyUnauthorized() public {
        // Non-dapp control user should not be able to set penalty
        vm.startPrank(user1);
        
        vm.expectRevert();
        marketManagerIsolated.setPenalty(1.15e18);
        
        vm.stopPrank();
    }
    
    function testSetPenaltyInvalidValue() public {
        vm.startPrank(dappControlUser);
        
        // penalty below minimum
        uint256 tooLowPenalty = 1.01e18;
        // should revert with MarketManager__InvalidParameter()
        vm.expectRevert(bytes4(0x65513fc1)); 
        marketManagerIsolated.setPenalty(tooLowPenalty);
        
        // penalty above maximum
        uint256 tooHighPenalty = 1.25e18; 
        // should revert with MarketManager__InvalidParameter()
        vm.expectRevert(bytes4(0x65513fc1)); 
        marketManagerIsolated.setPenalty(tooHighPenalty);
        
        vm.stopPrank();
    }
    
    function testResetPenalty() public {
        vm.startPrank(dappControlUser);
        
        // Set a penalty
        uint256 validPenalty = 1.15e18;
        marketManagerIsolated.setPenalty(validPenalty);
        assertEq(marketManagerIsolated.getLatestPenalty(), validPenalty);
        
        // Reset the penalty
        marketManagerIsolated.resetPenalty();
        
        // Check that the penalty was reset to the default
        uint256 defaultPenalty = 1.10e18; // 10% as set in setUp
        assertEq(marketManagerIsolated.getLatestPenalty(), defaultPenalty);
        
        vm.stopPrank();
    }
    
    function testGetLatestPenaltyDefault() public {
        // should return the default
        uint256 defaultPenalty = 1.10e18; // 10% as set in setUp
        assertEq(marketManagerIsolated.getLatestPenalty(), defaultPenalty);
    }

    function testResetPenaltyUnauthorized() public {
        vm.startPrank(user1);
        
        vm.expectRevert();
        marketManagerIsolated.resetPenalty();
        
        vm.stopPrank();
    }

    function testLiquidationWithDynamicPenalty() public {
        _prepareLiquidationIsolated();

        testSetPenalty();

        _prepareUSDC(user3, 250e6);

        usdc.approve(address(eUSDCIsolated), 250e6);
        eUSDCIsolated.liquidateExact(user1, 250e6, address(pBALRETHIsolated));
        vm.stopPrank();

    }
}