// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";


contract TransferTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        strategyCBALRETH.mint(100, address(this));
    }

    function test_strategyCTokenTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        strategyCBALRETH.transfer(user1, 0);
    }

    function test_strategyCTokenTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        strategyCBALRETH.transfer(user1, 1e18);
    }

    function test_strategyCTokenTransfer_success() public {
        uint256 balance = strategyCBALRETH.balanceOf(address(this));
        uint256 user1Balance = strategyCBALRETH.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit Transfer(address(this), user1, 100);

        strategyCBALRETH.transfer(user1, 100);

        assertEq(strategyCBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(strategyCBALRETH.balanceOf(user1), user1Balance + 100);
    }
}
