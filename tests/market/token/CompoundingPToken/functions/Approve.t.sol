// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingPToken } from "../TestBaseCompoundingPToken.sol";

contract CompoundingPTokenApproveTest is TestBaseCompoundingPToken {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    function test_compoundingPTokenApprove_success() public {
        uint256 allowance = pBALRETH.allowance(address(this), user1);

        vm.expectEmit(true, true, true, true, address(pBALRETH));
        emit Approval(address(this), user1, 100);

        pBALRETH.approve(user1, 100);

        assertEq(pBALRETH.allowance(address(this), user1), allowance + 100);
    }
}
