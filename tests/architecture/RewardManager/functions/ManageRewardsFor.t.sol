// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract ManageRewardsForTest is TestBaseRewardManager {
    event RewardPaid(address user, address rewardToken, uint256 amount);

    ClaimAction public action = ClaimAction(true, false, false, false);

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(rewardManager), 10000e6);
    }

    function test_manageRewardsFor_fail_whenNotDelegated() public {
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        rewardManager.manageRewardsFor(user1);
    }

    function test_manageRewardsFor_success() public {
        _skipRestrictionDuration();

        vm.startPrank(user1);

        rewardManager.setDelegateApproval(address(this), true);

        _prepareCVE(user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(100e18, false, action, "", 0);

        vm.stopPrank();

        vm.prank(address(veCVE));
        rewardManager.updateUserClaimIndex(user1, 1);

        assertEq(usdc.balanceOf(address(this)), 0);

        _recordEpochRewards(2, 1e6 * _ONE);

        vm.expectEmit(true, true, true, true);
        emit RewardPaid(user1, _USDC_ADDRESS, 100e6);

        rewardManager.manageRewardsFor(user1);

        assertEq(usdc.balanceOf(address(this)), 100e6);
    }
}
