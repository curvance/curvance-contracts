// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract NotifyBorrowTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_notifyBorrow_fail_whenCallerIsNotCToken() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.notifyBorrow(address(borrowableCUSDC), user1);
    }

    function test_notifyBorrow_success() public {
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.notifyBorrow(address(borrowableCUSDC), user1);

        assertEq(marketManagerIsolated.accountAssets(user1), block.timestamp);
    }
}
