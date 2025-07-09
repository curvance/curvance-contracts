// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";


contract StrategyCTokenTransferTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        simpleCBALRETH.mint(100, address(this));
    }

    function test_strategyCTokenTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        simpleCBALRETH.transfer(user1, 0);
    }

    function test_strategyCTokenTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        simpleCBALRETH.transfer(user1, 1e18);
    }

    function test_strategyCTokenTransfer_success() public {
        uint256 balance = simpleCBALRETH.balanceOf(address(this));
        uint256 user1Balance = simpleCBALRETH.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(simpleCBALRETH));
        emit Transfer(address(this), user1, 100);

        simpleCBALRETH.transfer(user1, 100);

        assertEq(simpleCBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(simpleCBALRETH.balanceOf(user1), user1Balance + 100);
    }
}
