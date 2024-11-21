// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingWithExitFeePToken } from "../TestBaseCompoundingWithExitFeePToken.sol";
import { CompoundingPToken } from "contracts/market/token/CompoundingPToken.sol";

contract CompoundingWithExitFeePTokenRedeemTest is
    TestBaseCompoundingWithExitFeePToken
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_compoundingWithExitFeePTokenRedeem_fail_whenNoEnoughToRedeem()
        public
    {
        vm.prank(address(1));

        vm.expectRevert();
        pBALRETHWithExitFee.redeem(100, address(this), address(this));
    }

    function test_compoundingWithExitFeePTokenRedeem_fail_whenAmountIsZero()
        public
    {
        pBALRETHWithExitFee.mint(100, address(this));

        vm.expectRevert(
            CompoundingPToken.CompoundingPToken__ZeroAssets.selector
        );
        pBALRETHWithExitFee.redeem(0, address(this), address(this));
    }

    function test_compoundingWithExitFeePTokenRedeem_success() public {
        pBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = pBALRETHWithExitFee.totalSupply();

        vm.expectEmit(true, true, true, true, address(pBALRETHWithExitFee));
        emit Transfer(address(this), address(0), 100);

        pBALRETHWithExitFee.redeem(100, address(this), address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance + 98);
        assertEq(pBALRETHWithExitFee.balanceOf(address(this)), balance - 100);
        assertEq(pBALRETHWithExitFee.totalSupply(), totalSupply - 100);
    }
}
