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
        deal(address(_DAI_ADDRESS), address(this), 77777);
        deal(address(_USDC_ADDRESS), address(this), 77777 + 100e6);

        dai.approve(address(borrowableCDAI), 77777);
        usdc.approve(address(borrowableCUSDC), 77777 + 100e6);

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 1_000_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);

        borrowableCUSDC.depositAsCollateral(100e6, address(this));

        assertEq(marketManagerIsolated.redeemPaused(), 1);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Redeem Paused", true);

        marketManagerIsolated.setRedeemPaused(true);

        assertEq(marketManagerIsolated.redeemPaused(), 2);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), 1, user1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.withdraw(100e6, address(this), address(this));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.redeem(100e6, address(this), address(this));

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit ActionPaused("Redeem Paused", false);

        marketManagerIsolated.setRedeemPaused(false);

        assertEq(marketManagerIsolated.redeemPaused(), 1);
    }
}
