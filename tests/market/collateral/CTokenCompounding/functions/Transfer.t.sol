// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCTokenCompounding } from "../TestBaseCTokenCompounding.sol";
import { GaugeErrors } from "contracts/gauge/GaugeErrors.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract CTokenCompoundingTransferTest is TestBaseCTokenCompounding {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        cBALRETH.mint(100, address(this));
    }

    function test_cTokenCompoundingTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(GaugeErrors.InvalidAmount.selector);
        cBALRETH.transfer(user1, 0);
    }

    function test_cTokenCompoundingTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManager.setTransferPaused(true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        cBALRETH.transfer(user1, 0);
    }

    function test_cTokenCompoundingTransfer_success() public {
        uint256 balance = cBALRETH.balanceOf(address(this));
        uint256 user1Balance = cBALRETH.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(cBALRETH));
        emit Transfer(address(this), user1, 100);

        cBALRETH.transfer(user1, 100);

        assertEq(cBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(cBALRETH.balanceOf(user1), user1Balance + 100);
    }
}
