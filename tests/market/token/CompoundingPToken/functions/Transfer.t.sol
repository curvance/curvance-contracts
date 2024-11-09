// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingPToken } from "../TestBaseCompoundingPToken.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract CompoundingPTokenTransferTest is TestBaseCompoundingPToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        pBALRETH.mint(100, address(this));
    }

    function test_CompoundingPTokenTransfer_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(GaugeManager.GaugeManager__InvalidAmount.selector);
        pBALRETH.transfer(user1, 0);
    }

    function test_CompoundingPTokenTransfer_fail_whenTransferIsNotAllowed()
        public
    {
        marketManager.setTransferPaused(true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        pBALRETH.transfer(user1, 0);
    }

    function test_CompoundingPTokenTransfer_success() public {
        uint256 balance = pBALRETH.balanceOf(address(this));
        uint256 user1Balance = pBALRETH.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(pBALRETH));
        emit Transfer(address(this), user1, 100);

        pBALRETH.transfer(user1, 100);

        assertEq(pBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(pBALRETH.balanceOf(user1), user1Balance + 100);
    }
}
