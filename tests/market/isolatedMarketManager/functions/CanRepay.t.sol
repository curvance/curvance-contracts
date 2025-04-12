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
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        vm.prank(address(eUSDC));
        marketManager.notifyBorrow(address(eUSDC), user1);

        vm.expectRevert(
            MarketManager.MarketManager__MinimumHoldPeriod.selector
        );
        marketManager.canRepay(address(eUSDC), user1);
    }

    function test_canRepay_success_whenPastMinimumHoldPeriod() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        vm.prank(address(eUSDC));
        marketManager.notifyBorrow(address(eUSDC), user1);

        skip(20 minutes);
        marketManager.canRepay(address(eUSDC), user1);
    }

    function test_canRepay_success() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
        marketManager.canRepay(address(eUSDC), user1);
    }
}
