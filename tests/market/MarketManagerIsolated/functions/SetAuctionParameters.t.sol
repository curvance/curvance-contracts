// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract SetAuctionParametersTest is TestBaseMarketIsolated {

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

    function test_setAuctionParameters_fail_whenUnauthorized() public {
        // // Non-dapp control user should not be able to set penalty
        vm.startPrank(user1);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), 1.15e18, 0.30e18);
        
        vm.stopPrank();
    }

    function test_setAuctionParameters_fail_whenTokenNotListed() public {
        vm.startPrank(dappControlUser);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector); 
        marketManagerIsolated.setAuctionParameters(user1, 1.15e18, 0.30e18);
        vm.stopPrank();
    }

    function test_setAuctionParameters_fail_whenCollateralizationOff() public {
        _setCTokenConfigCollateralOff(address(strategyCBALRETH), 0);

        vm.startPrank(dappControlUser);

        vm.expectRevert(MarketManagerIsolated.MarketManager__UnauthorizedLiquidation.selector); 
        marketManagerIsolated.setAuctionParameters(address(strategyCBALRETH), 1.15e18, 0.30e18);
        vm.stopPrank();
    }

    function test_setAuctionParameters_fail_whenInvalidValues() public {
        uint256 tooLowPenalty = 1.0001e18;
        uint256 tooHighPenalty = 1.25e18; 
        uint256 validPenalty = 1.15e18;
        uint256 tooHighCloseFactor = 1.51e18;
        uint256 tooLowCloseFactor = 1.09e18;
        uint256 validCloseFactor = 0.30e18;

        vm.startPrank(dappControlUser);
        
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

    function test_setAuctionParameters_success() public {
        _setAuctionConfigs(address(strategyCBALRETH), 1.15e18, 0.30e18);

        // Verify the penalty was set correctly
        (uint256 currentPenalty, uint256 currentCloseFactor) = marketManagerIsolated.getLatestAuctionParameters();
        assertEq(currentPenalty, 1.15e18);
        assertEq(currentCloseFactor, 0.30e18);
        vm.stopPrank();
    }


}