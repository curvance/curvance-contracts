// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";

contract UpdateUserClaimIndexTest is TestBaseRewardManager {
    function test_updateUserClaimIndex_fail_whenCallerIsVeCVE() public {
        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.updateUserClaimIndex(user1, 1);
    }

    function test_updateUserClaimIndex_success() public {
        assertEq(rewardManager.userNextClaimIndex(user1), 0);

        vm.prank(address(rewardManager.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        assertEq(rewardManager.userNextClaimIndex(user1), 1);
    }
}
