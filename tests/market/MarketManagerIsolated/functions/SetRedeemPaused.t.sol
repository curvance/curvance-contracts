// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract SetRedeemPausedTest is TestBaseMarketIsolated {
    event ActionPaused(string action, bool pauseState);

    function test_setRedeemPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setRedeemPaused(true);
    }

    function test_setRedeemPaused_success() public {
        deal(address(balRETH), address(this), 77777);
        deal(address(_USDC_ADDRESS), address(this), 77777);

        balRETH.approve(address(strategyCBALRETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        assertEq(marketManagerIsolated.redeemPaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Redeem Paused", true);

        marketManagerIsolated.setRedeemPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), 1, user1);

        assertEq(marketManagerIsolated.redeemPaused(), 2);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Redeem Paused", false);

        marketManagerIsolated.setRedeemPaused(false);

        assertEq(marketManagerIsolated.redeemPaused(), 1);
    }
}
