// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";


contract TransferFromTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        pendleStrategyCTokenSTETH.mint(100, address(this));
    }

    function test_strategyCTokenTransferFrom_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        pendleStrategyCTokenSTETH.transferFrom(address(this), user1, 0);
    }

    function test_strategyCTokenTransferFrom_fail_whenAllowanceIsInvalid()
        public
    {
        vm.expectRevert();
        pendleStrategyCTokenSTETH.transferFrom(user1, address(this), 100);
    }

    function test_strategyCTokenTransferFrom_fail_whenTransferIsNotAllowed()
        public
    {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        pendleStrategyCTokenSTETH.transferFrom(address(this), user1, 100);
    }

    function test_strategyCTokenTransferFrom_success() public {
        deal(address(pendleStrategyCTokenSTETH), address(this), 100e18);

        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(address(this));
        uint256 user1Balance = pendleStrategyCTokenSTETH.balanceOf(user1);

        pendleStrategyCTokenSTETH.approve(user1, 100e18);

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit Transfer(address(this), user1, 100e18);

        vm.prank(user1);
        pendleStrategyCTokenSTETH.transferFrom(address(this), user1, 100e18);

        assertEq(pendleStrategyCTokenSTETH.balanceOf(address(this)), balance - 100e18);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), user1Balance + 100e18);
    }

    function test_strategyCTokenTransferFrom_success_withMaxApproval() public {
        deal(address(pendleStrategyCTokenSTETH), address(this), 100e18);

        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(address(this));
        uint256 user1Balance = pendleStrategyCTokenSTETH.balanceOf(user1);

        pendleStrategyCTokenSTETH.approve(user1, type(uint256).max);

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit Transfer(address(this), user1, 100e18);

        vm.prank(user1);
        pendleStrategyCTokenSTETH.transferFrom(address(this), user1, 100e18);

        assertEq(pendleStrategyCTokenSTETH.balanceOf(address(this)), balance - 100e18);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), user1Balance + 100e18);
        assertEq(pendleStrategyCTokenSTETH.allowance(address(this), user1), type(uint256).max);
    }
}
