// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { LiquidationManager } from "contracts/market/LiquidationManager.sol";

contract LiquidateAccountTest is TestBaseMarketManager {
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
        marketManager.liquidateAccount(user1);
    }

    function test_liquidateAccount_fail_whenNotEligibleForLiquidation()
        public
    {
        _prepareLiquidation();

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
        _prepareLiquidation();

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
        _prepareLiquidation();

        centralRegistry.setSequencingStatus(true);

        vm.prank(user2);
        marketManager.queueAccountLiquidation(user1);

        vm.prank(user2, user2);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        marketManager.liquidateAccount(user1);
    }
}
