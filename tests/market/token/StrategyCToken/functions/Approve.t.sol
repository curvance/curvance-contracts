// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";

contract ApproveTest is TestBaseStrategyCToken {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    function test_strategyCTokenApprove_success() public {
        uint256 allowance = pendleStrategyCTokenSTETH.allowance(address(this), user1);

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit Approval(address(this), user1, 100);

        pendleStrategyCTokenSTETH.approve(user1, 100);

        assertEq(pendleStrategyCTokenSTETH.allowance(address(this), user1), allowance + 100);
    }
}
