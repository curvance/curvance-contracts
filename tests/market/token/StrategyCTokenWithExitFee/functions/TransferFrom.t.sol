// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";


contract StrategyCTokenWithExitFeeTransferFromTest is
    TestBaseStrategyCTokenWithExitFee
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        simpleCBALRETHWithExitFee.mint(100, address(this));
    }

    function test_strategyCTokenWithExitFeeTransferFrom_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        simpleCBALRETHWithExitFee.transferFrom(address(this), user1, 0);
    }

    function test_strategyCTokenWithExitFeeTransferFrom_fail_whenAllowanceIsInvalid()
        public
    {
        vm.expectRevert();
        simpleCBALRETHWithExitFee.transferFrom(user1, address(this), 100);
    }

    function test_strategyCTokenWithExitFeeTransferFrom_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        simpleCBALRETHWithExitFee.transferFrom(address(this), user1, 100);
    }

    function test_strategyCTokenWithExitFeeTransferFrom_success() public {
        uint256 balance = simpleCBALRETHWithExitFee.balanceOf(address(this));
        uint256 user1Balance = simpleCBALRETHWithExitFee.balanceOf(user1);

        simpleCBALRETHWithExitFee.approve(address(this), 100);

        vm.expectEmit(true, true, true, true, address(simpleCBALRETHWithExitFee));
        emit Transfer(address(this), user1, 100);

        simpleCBALRETHWithExitFee.transferFrom(address(this), user1, 100);

        assertEq(simpleCBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(simpleCBALRETHWithExitFee.balanceOf(user1), user1Balance + 100);
    }
}
