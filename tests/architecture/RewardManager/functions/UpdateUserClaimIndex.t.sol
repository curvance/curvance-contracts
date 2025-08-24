// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";

contract UpdateUserClaimIndexTest is TestBaseRewardManager {
    function test_updateUserClaimIndex_fail_whenCallerIsVeCVE() public {
        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.updateUserClaimIndex(user1, 1);
    }

    function test_updateUserClaimIndex_success() public {
        assertEq(rewardManager.userNextClaimIndex(user1), 0);

        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        assertEq(rewardManager.userNextClaimIndex(user1), 1);
    }
}
