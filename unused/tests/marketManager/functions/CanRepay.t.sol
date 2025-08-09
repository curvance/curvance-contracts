// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract CanRepayTest is TestBaseMarketManager {
    function test_canRepay_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canRepay(address(borrowableCUSDC), user1);
    }

    function test_canRepay_fail_withinMinimumHoldPeriod() public {
        marketManager.listToken(address(borrowableCUSDC));
        vm.prank(address(borrowableCUSDC));
        marketManager.notifyBorrow(address(borrowableCUSDC), user1);

        vm.expectRevert(
            MarketManager.MarketManager__MinimumHoldPeriod.selector
        );
        marketManager.canRepay(address(borrowableCUSDC), user1);
    }

    function test_canRepay_success_whenPastMinimumHoldPeriod() public {
        marketManager.listToken(address(borrowableCUSDC));
        vm.prank(address(borrowableCUSDC));
        marketManager.notifyBorrow(address(borrowableCUSDC), user1);

        skip(20 minutes);
        marketManager.canRepay(address(borrowableCUSDC), user1);
    }

    function test_canRepay_success() public {
        marketManager.listToken(address(borrowableCUSDC));
        marketManager.canRepay(address(borrowableCUSDC), user1);
    }
}
