// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TransferTest is TestBaseStrategyCTokenWithExitFee {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        strategyCBALRETHWithExitFee.mint(100, address(this));
    }

    function test_strategyCTokenWithExitFeeTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        strategyCBALRETHWithExitFee.transfer(user1, 0);
    }

    function test_strategyCTokenWithExitFeeTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        strategyCBALRETHWithExitFee.transfer(user1, 1e18);
    }

    function test_strategyCTokenWithExitFeeTransfer_success() public {
        uint256 balance = strategyCBALRETHWithExitFee.balanceOf(address(this));
        uint256 user1Balance = strategyCBALRETHWithExitFee.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(strategyCBALRETHWithExitFee));
        emit Transfer(address(this), user1, 100);

        strategyCBALRETHWithExitFee.transfer(user1, 100);

        assertEq(strategyCBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(strategyCBALRETHWithExitFee.balanceOf(user1), user1Balance + 100);
    }
}
