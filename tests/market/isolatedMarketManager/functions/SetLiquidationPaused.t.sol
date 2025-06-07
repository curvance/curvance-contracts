// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract SetLiquidationPausedTest is TestBaseMarketManagerIsolated {
    event ActionPaused(string action, bool pauseState);


    function test_setLiquidationPaused_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setLiquidationPaused(true);
    }

    function test_setLiquidationPaused_success() public {
        assertEq(marketManagerIsolated.liquidationPaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Liquidation Paused", true);

        marketManagerIsolated.setLiquidationPaused(true);

        assertEq(marketManagerIsolated.liquidationPaused(), 2);
    }
}
