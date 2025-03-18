// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManager } from "tests/market/marketManager/TestBaseMarketManager.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract DynamicPenaltyTest is TestBaseMarketManager {
    address dappControlUser;

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

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setPTokenCollateralCaps(tokens, caps);
        
        // Create a dapp control user
        dappControlUser = makeAddr("dappControlUser");
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuthorizedAtlasDAppControl(dappControlUser);
        vm.stopPrank();
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

    function testLiquidationWithPenalty() public {
        _prepareLiquidationIsolated();

        vm.startPrank(user2);
        usdc.approve(address(eUSDCIsolated), 250e6);
        eUSDCIsolated.liquidateExact(user1, 250e6, address(pBALRETHIsolated));
        vm.stopPrank();
    }

    function _prepareLiquidationIsolated() internal {
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );

        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(1500e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        vm.prank(user1);
        usdc.approve(address(eUSDCIsolated), _ONE);

        usdc.approve(address(eUSDCIsolated), _ONE);
        marketManagerIsolated.listTokens(address(pBALRETHIsolated), address(eUSDCIsolated));
        
        eUSDCIsolated.depositReserves(1000e6);
        _prepareBALRETH(address(this), 10e18);
        balRETH.approve(address(pBALRETHIsolated), 10e18);

        marketManagerIsolated.listTokens(address(pBALRETHIsolated), address(eUSDCIsolated));

        vm.startPrank(user1);
        balRETH.approve(address(pBALRETHIsolated), _ONE);
        pBALRETHIsolated.deposit(_ONE, user1);
        vm.stopPrank();

        vm.startPrank(user1);
        usdc.approve(address(eUSDCIsolated), _ONE);
        eUSDCIsolated.mint(_ONE);
        vm.stopPrank();

        marketManagerIsolated.postCollateral(user1, address(pBALRETHIsolated), _ONE - 1);

        eUSDCIsolated.borrow(1000e6);
        vm.stopPrank();
        
        skip(20 minutes);

        mockUsdcFeed.setMockAnswer(2e8);

        _prepareUSDC(user2, 1000e6);
    }

    function testResetPenaltyUnauthorized() public {
        vm.startPrank(user1);
        
        vm.expectRevert();
        marketManagerIsolated.resetPenalty();
        
        vm.stopPrank();
    }

    // function testPenaltyAffectsLiquidation() public {
        
    //     // Test liquidation with custom penalty 
    //     uint256 customPenalty = 1.15e18; // 15%
    //     vm.startPrank(dappControlUser);
    //     marketManagerIsolated.setPenalty(customPenalty);
    //     vm.stopPrank();
        
    //     // Set up borrower 
    //     deal(address(balRETH), borrower, 1e18);
    //     vm.startPrank(borrower);
    //     balRETH.approve(address(pBALRETHIsolated), 1e18);
    //     pBALRETHIsolated.deposit(1e18, borrower);
    //     marketManagerIsolated.postCollateral(borrower, address(pBALRETHIsolated), 1e18 - 1);
    //     vm.stopPrank();
        
    //     // Create a lender with USDC
    //     deal(address(_USDC_ADDRESS), lender, 10_000e6);
    //     vm.startPrank(lender);
    //     usdc.approve(address(eUSDCIsolated), 10_000e6);
    //     // Deposit USDC to get eTokens
    //     eUSDCIsolated.mint(10_000e6);
    //     vm.stopPrank();
        
    //     vm.startPrank(borrower);
    //     eUSDCIsolated.borrow(150e6);
    //     vm.stopPrank();
        
    //     skip(20 minutes);
        
    //     mockWethFeed.setMockAnswer(200e8); 
    //     mockRethFeed.setMockAnswer(200e8); 
        
    //     // Prepare liquidator 
    //     deal(address(_USDC_ADDRESS), liquidator, 50e6);
    //     vm.startPrank(liquidator);
    //     usdc.approve(address(eUSDCIsolated), 50e6);
        
    //     // Store collateral and debt balances before liquidation
    //     uint256 borrowerCollateralBefore = pBALRETHIsolated.balanceOf(borrower);
    //     uint256 liquidatorCollateralBefore = pBALRETHIsolated.balanceOf(liquidator);
    //     uint256 borrowerDebtBefore = eUSDCIsolated.debtBalanceCached(borrower);
        
    //     // Liquidate 20% of the debt
    //     uint256 liquidateAmount = 30e6;
    //     eUSDCIsolated.liquidateExact(borrower, liquidateAmount, address(pBALRETHIsolated));
        
    //     // Verify liquidation amounts
    //     uint256 liquidatorCollateralAfter = pBALRETHIsolated.balanceOf(liquidator);
    //     uint256 borrowerDebtAfter = eUSDCIsolated.debtBalanceCached(borrower);
        
    //     uint256 collateralSeized = liquidatorCollateralAfter - liquidatorCollateralBefore;
    //     uint256 debtReduced = borrowerDebtBefore - borrowerDebtAfter;

    //     assertEq(collateralSeized, 179964295301014470);
            
    //     vm.stopPrank();
    // }



}