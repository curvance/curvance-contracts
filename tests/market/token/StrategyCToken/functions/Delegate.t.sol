// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";

contract DelegateTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenDelegateDeposit_success() public {

        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(address(this));
        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();

        vm.prank(user1);
        pendleStrategyCTokenSTETH.setDelegateApproval(address(this), true);

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit Transfer(address(0), user1, 100);
        pendleStrategyCTokenSTETH.depositAsCollateralFor(100, user1);

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), balance + 100);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply + 100);
    }
}
