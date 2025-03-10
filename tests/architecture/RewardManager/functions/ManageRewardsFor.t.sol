// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";

contract ManageRewardsForTest is TestBaseRewardManager {
    event RewardPaid(address user, address rewardToken, uint256 amount);

    RewardsData public rewardsData = RewardsData(true, false, false, false);

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(rewardManager), 10000e6);
    }

    function test_manageRewardsFor_fail_whenNotDelegated() public {
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(0xcfdc5602);
        rewardManager.manageRewardsFor(user1);
    }

    function test_manageRewardsFor_success() public {
        _skipRestrictionDuration();

        vm.startPrank(user1);

        rewardManager.setDelegateApproval(address(this), true);

        _prepareCVE(user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(100e18, false, rewardsData, "", 0);

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
