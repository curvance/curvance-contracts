// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract LockAuctionCollateralTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();

        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        
        // List tokens in the market.
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);
    }

    function test_lockAuctionCollateral_fail_whenUnauthorized() public {
        // // Non-dapp control user should not be able to lock auction
        // collateral.
        vm.startPrank(user1);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.resetTransientLiquidationConfig();
        
        vm.stopPrank();
    }

    function test_lockAuctionCollateral_success() public {
        vm.startPrank(auctionPermsUser);

        marketManagerIsolated.resetTransientLiquidationConfig();
        vm.stopPrank();
    }


}