// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBasePTokenCompoundingWithExitFee } from "../TestBasePTokenCompoundingWithExitFee.sol";

contract PTokenCompoundingWithExitFeeApproveTest is
    TestBasePTokenCompoundingWithExitFee
{
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    function test_PTokenCompoundingWithExitFeeApprove_success() public {
        uint256 allowance = pBALRETHWithExitFee.allowance(
            address(this),
            user1
        );

        vm.expectEmit(true, true, true, true, address(pBALRETHWithExitFee));
        emit Approval(address(this), user1, 100);

        pBALRETHWithExitFee.approve(user1, 100);

        assertEq(
            pBALRETHWithExitFee.allowance(address(this), user1),
            allowance + 100
        );
    }
}
