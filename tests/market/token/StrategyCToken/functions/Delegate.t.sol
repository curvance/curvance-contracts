// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";

contract StrategyCTokenDelegateTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenDelegateDeposit_success() public {
        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = simpleCBALRETH.balanceOf(address(this));
        uint256 totalSupply = simpleCBALRETH.totalSupply();

        vm.prank(user1);
        simpleCBALRETH.setDelegateApproval(address(this), true);

        vm.expectEmit(true, true, true, true, address(simpleCBALRETH));
        emit Transfer(address(0), user1, 100);
        simpleCBALRETH.depositAsCollateralFor(100, user1);

        assertEq(simpleCBALRETH.balanceOf(user1), balance + 100);
        assertEq(simpleCBALRETH.totalSupply(), totalSupply + 100);
    }
}
