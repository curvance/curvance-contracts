// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract SetTransferPausedTest is TestBaseMarketManager {
    event ActionPaused(string action, bool pauseState);

    function test_setTransferPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setTransferPaused(true);
    }

    function test_setTransferPaused_success() public {
        marketManager.listToken(address(borrowableCUSDC));

        vm.prank(address(borrowableCUSDC));
        marketManager.canTransferEToken(address(borrowableCUSDC), address(this), 1);

        assertEq(marketManager.transferPaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit ActionPaused("Transfer Paused", true);

        marketManager.setTransferPaused(true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);

        vm.prank(address(borrowableCUSDC));
        marketManager.canTransferEToken(address(borrowableCUSDC), address(this), 1);

        assertEq(marketManager.transferPaused(), 2);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit ActionPaused("Transfer Paused", false);

        marketManager.setTransferPaused(false);

        assertEq(marketManager.transferPaused(), 1);
    }
}
