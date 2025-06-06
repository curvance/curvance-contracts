// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract SetTransferPausedTest is TestBaseMarketManagerIsolated {
    event ActionPaused(string action, bool pauseState);

    function test_setTransferPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManager.setTransferPaused(true);
    }

    function test_setTransferPaused_success() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        vm.prank(address(eUSDC));
        marketManager.canTransferEToken(address(eUSDC), address(this), 1);

        assertEq(marketManager.transferPaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit ActionPaused("Transfer Paused", true);

        marketManager.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);

        vm.prank(address(eUSDC));
        marketManager.canTransferEToken(address(eUSDC), address(this), 1);

        assertEq(marketManager.transferPaused(), 2);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit ActionPaused("Transfer Paused", false);

        marketManager.setTransferPaused(false);

        assertEq(marketManager.transferPaused(), 1);
    }
}
