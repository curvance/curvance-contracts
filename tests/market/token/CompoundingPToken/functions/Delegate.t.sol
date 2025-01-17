// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingPToken } from "../TestBaseCompoundingPToken.sol";

contract CompoundingPTokenDelegateTest is TestBaseCompoundingPToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_compoundingPTokenDelegateDeposit_success() public {
        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETH.balanceOf(address(this));
        uint256 totalSupply = pBALRETH.totalSupply();

        vm.prank(user1);
        pBALRETH.setDelegateApproval(address(this), true);

        vm.expectEmit(true, true, true, true, address(pBALRETH));
        emit Transfer(address(0), user1, 100);
        pBALRETH.depositAsCollateralFor(100, user1);

        assertEq(pBALRETH.balanceOf(user1), balance + 100);
        assertEq(pBALRETH.totalSupply(), totalSupply + 100);
    }
}
