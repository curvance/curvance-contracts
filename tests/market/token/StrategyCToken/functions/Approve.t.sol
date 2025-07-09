// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";

contract StrategyCTokenApproveTest is TestBaseStrategyCToken {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    function test_strategyCTokenApprove_success() public {
        uint256 allowance = simpleCBALRETH.allowance(address(this), user1);

        vm.expectEmit(true, true, true, true, address(simpleCBALRETH));
        emit Approval(address(this), user1, 100);

        simpleCBALRETH.approve(user1, 100);

        assertEq(simpleCBALRETH.allowance(address(this), user1), allowance + 100);
    }
}
