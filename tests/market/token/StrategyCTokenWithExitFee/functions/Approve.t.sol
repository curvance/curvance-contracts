// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";

contract StrategyCTokenWithExitFeeApproveTest is
    TestBaseStrategyCTokenWithExitFee
{
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    function test_strategyCTokenWithExitFeeApprove_success() public {
        uint256 allowance = strategyCBALRETHWithExitFee.allowance(
            address(this),
            user1
        );

        vm.expectEmit(true, true, true, true, address(strategyCBALRETHWithExitFee));
        emit Approval(address(this), user1, 100);

        strategyCBALRETHWithExitFee.approve(user1, 100);

        assertEq(
            strategyCBALRETHWithExitFee.allowance(address(this), user1),
            allowance + 100
        );
    }
}
