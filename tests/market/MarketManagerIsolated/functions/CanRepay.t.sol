// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract CanRepayTest is TestBaseMarketIsolated {
    function test_canRepay_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canRepay(address(borrowableCUSDC), user1);
    }

    function test_canRepay_fail_withinMinimumHoldPeriod() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.notifyBorrow(address(borrowableCUSDC), user1);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        marketManagerIsolated.canRepay(address(borrowableCUSDC), user1);
    }

    function test_canRepay_success_whenPastMinimumHoldPeriod() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.notifyBorrow(address(borrowableCUSDC), user1);

        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

        marketManagerIsolated.canRepay(address(borrowableCUSDC), user1);
    }

    function test_canRepay_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
        marketManagerIsolated.canRepay(address(borrowableCUSDC), user1);
    }
}
