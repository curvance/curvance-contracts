// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract SetTransferPausedTest is TestBaseMarketIsolated {
    event ActionPaused(string action, bool pauseState);

    function test_setTransferPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setTransferPaused(true);
    }

    function test_setTransferPaused_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canTransfer(address(borrowableCUSDC), 100, address(this), 0, 1, false);

        assertEq(marketManagerIsolated.transferPaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Transfer Paused", true);

        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canTransfer(address(borrowableCUSDC), 100, address(this), 0, 1, false);

        assertEq(marketManagerIsolated.transferPaused(), 2);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Transfer Paused", false);

        marketManagerIsolated.setTransferPaused(false);

        assertEq(marketManagerIsolated.transferPaused(), 1);
    }
}
