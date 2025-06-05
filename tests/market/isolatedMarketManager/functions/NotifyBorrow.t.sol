// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";


contract NotifyBorrowTest is TestBaseMarketManagerIsolated {
    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));
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
