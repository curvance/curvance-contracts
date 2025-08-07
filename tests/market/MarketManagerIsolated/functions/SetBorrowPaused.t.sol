// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract SetBorrowPausedTest is TestBaseMarketIsolated {
    event TokenActionPaused(address cToken, string action, bool pauseState);

    function test_setBorrowPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);
    }

    function test_setBorrowPaused_fail_whenCTokenIsNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);
    }

    function test_setBorrowPaused_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        assert(_borrowPaused(address(borrowableCUSDC)));

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(borrowableCUSDC), "Borrow Paused", true);

        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        assert(!_borrowPaused(address(borrowableCUSDC)));

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(borrowableCUSDC), "Borrow Paused", false);

        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), false);

        assert(_borrowPaused(address(borrowableCUSDC)));
    }

    function _borrowPaused(address cToken) internal returns (bool isPaused) {
        (, , isPaused) = marketManagerIsolated.actionDisabled(cToken);
    }
}
