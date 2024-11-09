// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";

contract ETokenApproveTest is TestBaseEToken {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    function test_eTokenApprove_success() public {
        uint256 allowance = eUSDC.allowance(address(this), user1);

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Approval(address(this), user1, 100e6);

        eUSDC.approve(user1, 100e6);

        assertEq(eUSDC.allowance(address(this), user1), allowance + 100e6);
    }
}
