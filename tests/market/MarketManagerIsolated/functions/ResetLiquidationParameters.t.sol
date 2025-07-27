// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract ResetLiquidationConfigTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // List tokens in the market.
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
    }

    function test_resetLiquidationConfig_fail_whenUnauthorized() public {
        vm.startPrank(user1);
        
        vm.expectRevert();
        marketManagerIsolated.resetLiquidationConfig();
        
        vm.stopPrank();
    }

    function test_resetLiquidationConfig_success() public {
        vm.startPrank(dappControlUser);
        
        uint256 validPenalty = 1.15e18;
        uint256 validCloseFactor = 0.30e18;
        marketManagerIsolated.setLiquidationConfig(address(strategyCBALRETH), validPenalty, validCloseFactor);

        (uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getLiquidationConfig();
        assertEq(currentPenalty, validPenalty);
        assertEq(currentCloseFactor, validCloseFactor);
        
        marketManagerIsolated.resetLiquidationConfig();
        
        // uint256 defaultPenalty = 1.10e18; // Not used anymore because getLiquidationConfig does not return default penalties anymore.
        (currentPenalty, currentCloseFactor) = marketManagerIsolated.getLiquidationConfig();
        assertEq(currentPenalty, 0);
        assertEq(currentCloseFactor, 0);
        
        vm.stopPrank();
    }
}