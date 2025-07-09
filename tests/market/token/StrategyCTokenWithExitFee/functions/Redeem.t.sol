// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract StrategyCTokenWithExitFeeRedeemTest is
    TestBaseStrategyCTokenWithExitFee
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenWithExitFeeRedeem_fail_whenNoEnoughToRedeem()
        public
    {
        vm.prank(address(1));
        vm.expectRevert();
        simpleCBALRETHWithExitFee.redeem(100, address(this), address(this));
    }
    function test_strategyCTokenWithExitFeeRedeem_fail_whenAmountIsZero()
        public
    {
        simpleCBALRETHWithExitFee.mint(100, address(this));
        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );
        simpleCBALRETHWithExitFee.redeem(0, address(this), address(this));
    }

    function test_strategyCTokenWithExitFeeRedeem_success() public {
        simpleCBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = simpleCBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = simpleCBALRETHWithExitFee.totalSupply();

        vm.expectEmit(true, true, true, true, address(simpleCBALRETHWithExitFee));
        emit Transfer(address(this), address(0), 100);
        simpleCBALRETHWithExitFee.redeem(100, address(this), address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance + 98);
        assertEq(simpleCBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(simpleCBALRETHWithExitFee.totalSupply(), totalSupply - 100);
    }


}
