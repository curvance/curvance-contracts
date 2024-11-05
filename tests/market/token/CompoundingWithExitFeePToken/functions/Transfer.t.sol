// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingWithExitFeePToken } from "../TestBaseCompoundingWithExitFeePToken.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract CompoundingWithExitFeePTokenTransferTest is
    TestBaseCompoundingWithExitFeePToken
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        pBALRETHWithExitFee.mint(100, address(this));
    }

    function test_CompoundingWithExitFeePTokenTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(GaugeManager.GaugeManager__InvalidAmount.selector);
        pBALRETHWithExitFee.transfer(user1, 0);
    }

    function test_CompoundingWithExitFeePTokenTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManager.setTransferPaused(true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        pBALRETHWithExitFee.transfer(user1, 0);
    }

    function test_CompoundingWithExitFeePTokenTransfer_success() public {
        uint256 balance = pBALRETHWithExitFee.balanceOf(address(this));
        uint256 user1Balance = pBALRETHWithExitFee.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(pBALRETHWithExitFee));
        emit Transfer(address(this), user1, 100);

        pBALRETHWithExitFee.transfer(user1, 100);

        assertEq(pBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(pBALRETHWithExitFee.balanceOf(user1), user1Balance + 100);
    }
}
