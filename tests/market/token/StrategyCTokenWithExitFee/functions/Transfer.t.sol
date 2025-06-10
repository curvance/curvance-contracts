// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";


contract StrategyCTokenWithExitFeeTransferTest is
    TestBaseStrategyCTokenWithExitFee
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        pBALRETHWithExitFee.mint(100, address(this));
    }

    function test_strategyCTokenWithExitFeeTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BasePToken.BasePToken__EmptyAction.selector);
        pBALRETHWithExitFee.transfer(user1, 0);
    }

    function test_strategyCTokenWithExitFeeTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(marketManagerIsolated.MarketManager__Paused.selector);
        pBALRETHWithExitFee.transfer(user1, 0);
    }

    function test_strategyCTokenWithExitFeeTransfer_success() public {
        uint256 balance = pBALRETHWithExitFee.balanceOf(address(this));
        uint256 user1Balance = pBALRETHWithExitFee.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(pBALRETHWithExitFee));
        emit Transfer(address(this), user1, 100);

        pBALRETHWithExitFee.transfer(user1, 100);

        assertEq(pBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(pBALRETHWithExitFee.balanceOf(user1), user1Balance + 100);
    }
}
