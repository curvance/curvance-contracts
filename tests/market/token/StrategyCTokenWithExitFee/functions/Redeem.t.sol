// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract RedeemTest is TestBaseStrategyCTokenWithExitFee {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenWithExitFeeRedeem_fail_whenNotEnoughToRedeem()
        public
    {
        vm.prank(address(1));
        vm.expectRevert();
        strategyCBALRETHWithExitFee.redeem(100, address(this), address(this));
    }
    function test_strategyCTokenWithExitFeeRedeem_fail_whenAmountIsZero()
        public
    {
        strategyCBALRETHWithExitFee.mint(100, address(this));
        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );
        strategyCBALRETHWithExitFee.redeem(0, address(this), address(this));
    }

    function test_strategyCTokenWithExitFeeRedeem_success() public {
        strategyCBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = strategyCBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = strategyCBALRETHWithExitFee.totalSupply();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETHWithExitFee));
        emit Transfer(address(this), address(0), 100);
        strategyCBALRETHWithExitFee.redeem(100, address(this), address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance + 98);
        assertEq(strategyCBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(strategyCBALRETHWithExitFee.totalSupply(), totalSupply - 100);
    }


}
