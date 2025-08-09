// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract SetBorrowPausedTest is TestBaseMarketManager {
    event TokenActionPaused(address mToken, string action, bool pauseState);

    function test_setBorrowPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setBorrowPaused(address(borrowableCUSDC), true);
    }

    function test_setBorrowPaused_fail_whenMTokenIsNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.setBorrowPaused(address(borrowableCUSDC), true);
    }

    function test_setBorrowPaused_success() public {
        marketManager.listToken(address(borrowableCUSDC));

        assertEq(marketManager.borrowPaused(address(borrowableCUSDC)), 0);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenActionPaused(address(borrowableCUSDC), "Borrow Paused", true);

        marketManager.setBorrowPaused(address(borrowableCUSDC), true);

        assertEq(marketManager.borrowPaused(address(borrowableCUSDC)), 2);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenActionPaused(address(borrowableCUSDC), "Borrow Paused", false);

        marketManager.setBorrowPaused(address(borrowableCUSDC), false);

        assertEq(marketManager.borrowPaused(address(borrowableCUSDC)), 1);
    }
}
