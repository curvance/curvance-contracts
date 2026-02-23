// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";

contract ResetUserClaimIndexTest is TestBaseRewardManager {
    function test_resetUserClaimIndex_fail_whenCallerIsVeCVE() public {
        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.resetUserClaimIndex(user1);
    }

    function test_resetUserClaimIndex_success() public {
        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        assertEq(rewardManager.userNextClaimIndex(user1), 1);

        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.resetUserClaimIndex(user1);

        assertEq(rewardManager.userNextClaimIndex(user1), 0);
    }
}
