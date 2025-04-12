// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract CanRepayTest is TestBaseMarketManagerIsolated {
    function test_canRepay_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canRepay(address(eUSDC), user1);
    }

    function test_canRepay_fail_withinMinimumHoldPeriod() public {
        marketManager.listToken(address(eUSDC));
        vm.prank(address(eUSDC));
        marketManager.notifyBorrow(address(eUSDC), user1);

        vm.expectRevert(
            MarketManager.MarketManager__MinimumHoldPeriod.selector
        );
        marketManager.canRepay(address(eUSDC), user1);
    }

    function test_canRepay_success_whenPastMinimumHoldPeriod() public {
        marketManager.listToken(address(eUSDC));
        vm.prank(address(eUSDC));
        marketManager.notifyBorrow(address(eUSDC), user1);

        skip(20 minutes);
        marketManager.canRepay(address(eUSDC), user1);
    }

    function test_canRepay_success() public {
        marketManager.listToken(address(eUSDC));
        marketManager.canRepay(address(eUSDC), user1);
    }
}
