// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract SetSeizePausedTest is TestBaseMarketIsolated {
    event ActionPaused(string action, bool pauseState);

    function test_setSeizePaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setSeizePaused(true);
    }

    function test_setSeizePaused_success() public {
        deal(address(balRETH), address(this), 77777);
        deal(address(_USDC_ADDRESS), address(this), 77777);

        balRETH.approve(address(strategyCBALRETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        assertEq(marketManagerIsolated.seizePaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Seize Paused", true);

        marketManagerIsolated.setSeizePaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canSeize(address(strategyCBALRETH), address(borrowableCUSDC));

        assertEq(marketManagerIsolated.seizePaused(), 2);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Seize Paused", false);

        marketManagerIsolated.setSeizePaused(false);

        assertEq(marketManagerIsolated.seizePaused(), 1);
    }
}
