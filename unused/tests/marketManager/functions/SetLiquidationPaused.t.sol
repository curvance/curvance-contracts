// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract SetLiquidationPausedTest is TestBaseMarketManager {
    event ActionPaused(string action, bool pauseState);

    function test_setLiquidationPaused_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setLiquidationPaused(true);
    }

    function test_setLiquidationPaused_success() public {
        assertEq(marketManager.liquidationPaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit ActionPaused("Liquidation Paused", true);

        marketManager.setLiquidationPaused(true);

        assertEq(marketManager.liquidationPaused(), 2);
    }
}
