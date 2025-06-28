// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract SetTransferPausedTest is TestBaseMarketManagerIsolated {
    event ActionPaused(string action, bool pauseState);

    function test_setTransferPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setTransferPaused(true);
    }

    function test_setTransferPaused_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(pBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(eUSDC), 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        vm.prank(address(eUSDC));
        marketManagerIsolated.canTransfer(address(eUSDC), address(this), 100, 0, 1, false);

        assertEq(marketManagerIsolated.transferPaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Transfer Paused", true);

        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);

        vm.prank(address(eUSDC));
        marketManagerIsolated.canTransfer(address(eUSDC), address(this), 100, 0, 1, false);

        assertEq(marketManagerIsolated.transferPaused(), 2);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Transfer Paused", false);

        marketManagerIsolated.setTransferPaused(false);

        assertEq(marketManagerIsolated.transferPaused(), 1);
    }
}
