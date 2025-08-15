// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";

contract BorrowableCTokenApproveTest is TestBaseBorrowableCToken {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    function test_borrowableCTokenApprove_success() public {
        uint256 allowance = borrowableCUSDC.allowance(address(this), user1);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Approval(address(this), user1, 100e6);

        borrowableCUSDC.approve(user1, 100e6);

        assertEq(borrowableCUSDC.allowance(address(this), user1), allowance + 100e6);
    }
}
