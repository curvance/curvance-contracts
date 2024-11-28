// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract SetDelegateApprovalTest is TestBaseRewardManager {
    event DelegateApproval(
        address indexed user,
        address indexed delegate,
        uint256 approvalIndex,
        bool isApproved
    );

    function test_setDelegateApproval_fail_whenDelegationIsDisabled() public {
        vm.startPrank(user1);

        centralRegistry.setDelegable(true);

        vm.expectRevert(
            PluginDelegable.PluginDelegable__DelegatingDisabled.selector
        );
        rewardManager.setDelegateApproval(user2, true);

        vm.stopPrank();
    }

    function test_setDelegateApproval_fail_whenCooldownIsNotEnded() public {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setDelegable(true);
        centralRegistry.setDelegable(false);

        vm.expectRevert(
            PluginDelegable.PluginDelegable__DelegatingDisabled.selector
        );
        rewardManager.setDelegateApproval(user2, true);

        vm.stopPrank();
    }

    function test_setDelegateApproval_success() public {
        assertFalse(rewardManager.isDelegate(user1, user2));
        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit DelegateApproval(user1, user2, 0, true);

        rewardManager.setDelegateApproval(user2, true);

        assertTrue(rewardManager.isDelegate(user1, user2));
    }
}
