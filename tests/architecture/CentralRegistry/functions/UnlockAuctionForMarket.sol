// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract UnlockAuctionForMarketTest is TestBaseMarketIsolated {

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

    function test_unlockAuctionForMarket_fail_whenUnauthorized() public {
        // // Non-dapp control user should not be able to set penalty
        vm.startPrank(user1);
        
        vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
        centralRegistry.unlockAuctionForMarket(address(strategyCBALRETH));
        
        vm.stopPrank();
    }

    function test_unlockAuctionForMarket_success() public {
        vm.startPrank(auctionPermsUser);

        marketManagerIsolated.setTransientLiquidationConfig(
            address(strategyCBALRETH),
            11500,
            3000
        );
        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));

        vm.stopPrank();
    }


}