// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract SetBorrowPausedTest is TestBaseMarketManagerIsolated {
    event TokenActionPaused(address mToken, string action, bool pauseState);

    function test_setBorrowPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setBorrowPaused(address(eUSDC), true);
    }

    function test_setBorrowPaused_fail_whenMTokenIsNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.setBorrowPaused(address(eUSDC), true);
    }

    function test_setBorrowPaused_success() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        assertEq(marketManagerIsolated.borrowPaused(address(eUSDC)), 0);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(eUSDC), "Borrow Paused", true);

        marketManagerIsolated.setBorrowPaused(address(eUSDC), true);

        assertEq(marketManagerIsolated.borrowPaused(address(eUSDC)), 2);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(eUSDC), "Borrow Paused", false);

        marketManagerIsolated.setBorrowPaused(address(eUSDC), false);

        assertEq(marketManagerIsolated.borrowPaused(address(eUSDC)), 1);
    }
}
