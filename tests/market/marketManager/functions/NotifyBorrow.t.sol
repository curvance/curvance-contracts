// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract NotifyBorrowTest is TestBaseMarketManager {
    event MarketEntered(address mToken, address account);

    function setUp() public override {
        super.setUp();

        marketManager.listToken(address(eUSDC));
    }

    function test_notifyBorrow_fail_whenCallerIsNotMToken() public {
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.notifyBorrow(address(eUSDC), user1);
    }

    function test_notifyBorrow_success() public {
        vm.prank(address(eUSDC));
        marketManager.notifyBorrow(address(eUSDC), user1);

        assertEq(marketManager.accountAssets(user1), block.timestamp);
    }
}
