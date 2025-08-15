// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract SetLiquidationPausedTest is TestBaseMarketIsolated {
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
