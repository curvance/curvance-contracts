// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";


contract TransferFromTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        strategyCBALRETH.mint(100, address(this));
    }

    function test_strategyCTokenTransferFrom_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        strategyCBALRETH.transferFrom(address(this), user1, 0);
    }

    function test_strategyCTokenTransferFrom_fail_whenAllowanceIsInvalid()
        public
    {
        vm.expectRevert();
        strategyCBALRETH.transferFrom(user1, address(this), 100);
    }

    function test_strategyCTokenTransferFrom_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        strategyCBALRETH.transferFrom(address(this), user1, 100);
    }

    function test_strategyCTokenTransferFrom_success() public {
        uint256 balance = strategyCBALRETH.balanceOf(address(this));
        uint256 user1Balance = strategyCBALRETH.balanceOf(user1);

        strategyCBALRETH.approve(address(this), 100);

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit Transfer(address(this), user1, 100);

        strategyCBALRETH.transferFrom(address(this), user1, 100);

        assertEq(strategyCBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(strategyCBALRETH.balanceOf(user1), user1Balance + 100);
    }
}
