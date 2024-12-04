// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

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
}
