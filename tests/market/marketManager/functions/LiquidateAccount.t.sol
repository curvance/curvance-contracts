// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { LiquidationManager } from "contracts/market/LiquidationManager.sol";

contract LiquidateAccountTest is TestBaseMarketManager {
    function setUp() public override {
        super.setUp();
        _prepareLiquidation();
    }

    function test_liquidateAccount_fail_whenCallerIsAccount() public {
        vm.prank(user1);

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.liquidateAccount(user1);
    }

    function test_liquidateAccount_fail_whenLiquidationsArePaused() public {
        marketManager.setSeizePaused(true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.liquidateAccount(user1);
    }

    function test_liquidateAccount_fail_whenNoLiquidationAvailable() public {
        vm.prank(user2);

        vm.expectRevert(
            MarketManager.MarketManager__NoLiquidationAvailable.selector
        );
        marketManager.liquidateAccount(address(1));
    }

    function test_liquidateAccount_fail_whenNotEligibleForLiquidation()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.prank(user2, user2);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        marketManager.liquidateAccount(user1);
    }

    function test_liquidateAccount_fail_whenLiquidationWindowHasPassed()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.prank(user2);
        marketManager.queueAccountLiquidation(user1);

        skip(31);

        vm.prank(user2, user2);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        marketManager.liquidateAccount(user1);
    }

    function test_liquidateAccount_fail_whenLiquidatorHasNoPriorityAccess()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.prank(user2);
        marketManager.queueAccountLiquidation(user1);

        vm.prank(user2, user2);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        marketManager.liquidateAccount(user1);
    }

    function test_liquidateAccount_success() public {
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), 1000e6);
        marketManager.liquidateAccount(user1);
        vm.stopPrank();

        _checkLiquidationResult();
    }

    function test_liquidateAccount_success_byWhitelistedBundler() public {
        address bundler = makeAddr("bundler");

        centralRegistry.setSequencingStatus(true);

        vm.prank(user2);
        usdc.approve(address(eUSDC), 1000e6);

        vm.prank(user2, bundler);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        marketManager.liquidateAccount(user1);

        centralRegistry.setBundler(bundler, true);

        vm.prank(user2, bundler);
        marketManager.liquidateAccount(user1);

        _checkLiquidationResult();
    }

    function test_liquidateAccount_success_withPriorityQueueLiquidation()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.startPrank(user2, address(1));

        marketManager.queueAccountLiquidation(user1);
        usdc.approve(address(eUSDC), 1000e6);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        marketManager.liquidateAccount(user1);

        skip(1);
        marketManager.liquidateAccount(user1);

        vm.stopPrank();

        _checkLiquidationResult();
    }

    function test_liquidateAccount_success_withRegularQueueLiquidation()
        public
    {
        centralRegistry.setSequencingStatus(true);

        // Prepare user3 as liquidator
        _prepareUSDC(user3, 250 ether);

        vm.startPrank(user2, address(1));

        marketManager.queueAccountLiquidation(user1);
        usdc.approve(address(eUSDC), 1000e6);
        vm.stopPrank();

        vm.startPrank(user3, address(2));
        usdc.approve(address(eUSDC), 1000e6);

        skip(1);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        marketManager.liquidateAccount(user1);

        skip(1);
        marketManager.liquidateAccount(user1);

        vm.stopPrank();

        _checkLiquidationResult();
    }

    function _checkLiquidationResult() internal {
        assertApproxEqAbs(pBALRETH.balanceOf(user1), 0, 1);
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertEq(eUSDC.debtBalanceCached(user1), 0);
        assertApproxEqRel(eUSDC.exchangeRateCached(), _ONE, 0.01e18);
    }
}
