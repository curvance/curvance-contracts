// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract NotifyBorrowTest is TestBaseMarketManager {
    function setUp() public override {
        super.setUp();

        marketManager.listToken(address(borrowableCUSDC));
    }

    function test_notifyBorrow_fail_whenCallerIsNotMToken() public {
        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.notifyBorrow(address(borrowableCUSDC), user1);
    }

    function test_notifyBorrow_success() public {
        vm.prank(address(borrowableCUSDC));
        marketManager.notifyBorrow(address(borrowableCUSDC), user1);

        assertEq(marketManager.accountAssets(user1), block.timestamp);
    }
}
