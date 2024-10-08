// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBasePTokenCompounding } from "../TestBasePTokenCompounding.sol";
import { PTokenCompounding } from "contracts/market/token/PTokenCompounding.sol";

contract PTokenCompoundingRedeemTest is TestBasePTokenCompounding {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_pTokenCompoundingRedeem_fail_whenNoEnoughToRedeem() public {
        vm.prank(address(1));

        vm.expectRevert();
        pBALRETH.redeem(100, address(this), address(this));
    }

    function test_pTokenCompoundingRedeem_fail_whenAmountIsZero() public {
        pBALRETH.mint(100, address(this));

        vm.expectRevert(
            PTokenCompounding.PTokenCompounding__ZeroAssets.selector
        );
        pBALRETH.redeem(0, address(this), address(this));
    }

    function test_pTokenCompoundingRedeem_success() public {
        pBALRETH.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETH.balanceOf(address(this));
        uint256 totalSupply = pBALRETH.totalSupply();

        vm.expectEmit(true, true, true, true, address(pBALRETH));
        emit Transfer(address(this), address(0), 100);

        pBALRETH.redeem(100, address(this), address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance + 100);
        assertEq(pBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(pBALRETH.totalSupply(), totalSupply - 100);
    }
}
