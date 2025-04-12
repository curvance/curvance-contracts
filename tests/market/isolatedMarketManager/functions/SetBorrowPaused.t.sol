// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract SetBorrowPausedTest is TestBaseMarketManagerIsolated {
    event TokenActionPaused(address mToken, string action, bool pauseState);

    function test_setBorrowPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setBorrowPaused(address(eUSDC), true);
    }

    function test_setBorrowPaused_fail_whenMTokenIsNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.setBorrowPaused(address(eUSDC), true);
    }

    function test_setBorrowPaused_success() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        assertEq(marketManager.borrowPaused(address(eUSDC)), 0);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenActionPaused(address(eUSDC), "Borrow Paused", true);

        marketManager.setBorrowPaused(address(eUSDC), true);

        assertEq(marketManager.borrowPaused(address(eUSDC)), 2);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenActionPaused(address(eUSDC), "Borrow Paused", false);

        marketManager.setBorrowPaused(address(eUSDC), false);

        assertEq(marketManager.borrowPaused(address(eUSDC)), 1);
    }
}
