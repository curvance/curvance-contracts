// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";


contract StrategyCTokenWithExitFeeTransferTest is
    TestBaseStrategyCTokenWithExitFee
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        simpleCBALRETHWithExitFee.mint(100, address(this));
    }

    function test_strategyCTokenWithExitFeeTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        simpleCBALRETHWithExitFee.transfer(user1, 0);
    }

    function test_strategyCTokenWithExitFeeTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        simpleCBALRETHWithExitFee.transfer(user1, 1e18);
    }

    function test_strategyCTokenWithExitFeeTransfer_success() public {
        uint256 balance = simpleCBALRETHWithExitFee.balanceOf(address(this));
        uint256 user1Balance = simpleCBALRETHWithExitFee.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(simpleCBALRETHWithExitFee));
        emit Transfer(address(this), user1, 100);

        simpleCBALRETHWithExitFee.transfer(user1, 100);

        assertEq(simpleCBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(simpleCBALRETHWithExitFee.balanceOf(user1), user1Balance + 100);
    }
}
