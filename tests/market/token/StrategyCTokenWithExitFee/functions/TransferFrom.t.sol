// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TransferFromTest is TestBaseStrategyCTokenWithExitFee {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        strategyCBALRETHWithExitFee.mint(100, address(this));
    }

    function test_strategyCTokenWithExitFeeTransferFrom_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        strategyCBALRETHWithExitFee.transferFrom(address(this), user1, 0);
    }

    function test_strategyCTokenWithExitFeeTransferFrom_fail_whenAllowanceIsInvalid()
        public
    {
        vm.expectRevert();
        strategyCBALRETHWithExitFee.transferFrom(user1, address(this), 100);
    }

    function test_strategyCTokenWithExitFeeTransferFrom_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        strategyCBALRETHWithExitFee.transferFrom(address(this), user1, 100);
    }

    function test_strategyCTokenWithExitFeeTransferFrom_success() public {
        uint256 balance = strategyCBALRETHWithExitFee.balanceOf(address(this));
        uint256 user1Balance = strategyCBALRETHWithExitFee.balanceOf(user1);

        strategyCBALRETHWithExitFee.approve(address(this), 100);

        vm.expectEmit(true, true, true, true, address(strategyCBALRETHWithExitFee));
        emit Transfer(address(this), user1, 100);

        strategyCBALRETHWithExitFee.transferFrom(address(this), user1, 100);

        assertEq(strategyCBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(strategyCBALRETHWithExitFee.balanceOf(user1), user1Balance + 100);
    }
}
