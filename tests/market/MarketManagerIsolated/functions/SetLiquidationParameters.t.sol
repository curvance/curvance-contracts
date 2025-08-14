// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract SetLiquidationConfigTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // List tokens in the market.
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigCollateralOff(address(strategyCBALRETH), 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
    }

    function test_setLiquidationConfig_fail_whenUnauthorized() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        // // Non-dapp control user should not be able to set penalty
        vm.startPrank(user1);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), 1.15e18, 0.30e18);
        
        vm.stopPrank();
    }

    function test_setLiquidationConfig_fail_whenTokenNotListed() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        vm.startPrank(dappControlUser);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector); 
        marketManagerIsolated.setLiquidationConfig(user1, 1.15e18, 0.30e18);
        vm.stopPrank();
    }

    function test_setLiquidationConfig_fail_whenCollateralizationOff() public {
        vm.startPrank(dappControlUser);

        vm.expectRevert(MarketManagerIsolated.MarketManager__UnauthorizedLiquidation.selector); 
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), 1.15e18, 0.30e18);
        vm.stopPrank();
    }

    function test_setLiquidationConfig_fail_whenInvalidValues() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        uint256 tooLowPenalty = 1.0001e18;
        uint256 tooHighPenalty = 1.25e18; 
        uint256 validPenalty = 1.15e18;
        uint256 tooHighCloseFactor = 1.51e18;
        uint256 tooLowCloseFactor = 1.09e18;
        uint256 validCloseFactor = 0.30e18;

        vm.startPrank(dappControlUser);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), tooLowPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), tooHighPenalty, validCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), validPenalty, tooHighCloseFactor);

        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector); 
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), validPenalty, tooLowCloseFactor);

        vm.stopPrank();
    }

    function test_setLiquidationConfig_success() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setAuctionConfigs(address(strategyCBALRETH), 11500, 3000);

        // Verify the penalty was set correctly
        (uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getLiquidationConfig();
        assertEq(currentPenalty, 11500);
        assertEq(currentCloseFactor, 3000);
        vm.stopPrank();
    }


}