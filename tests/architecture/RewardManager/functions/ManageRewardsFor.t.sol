// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";

contract ManageRewardsForTest is TestBaseRewardManager {
    event RewardPaid(address user, address rewardToken, uint256 amount);

    RewardsData public rewardsData = RewardsData(true, false, false, false);

    function setUp() public override {
        super.setUp();

        deal(_USDC_ADDRESS, address(rewardManager), 10000e6);
    }

    function test_manageRewardsFor_fail_whenNotDelegated() public {
        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.manageRewardsFor(user1);
    }

    function test_manageRewardsFor_success() public {
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.protocolMessagingHub());
            rewardManager.recordEpochRewards(1e6);
        }

        skip(veCVE.RESTRICTION_DURATION() + 1);

        vm.startPrank(user1);

        rewardManager.setDelegateApproval(address(this), true);

        deal(address(cve), user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(100e18, false, rewardsData, "0x", 0);

        vm.stopPrank();

        vm.prank(address(veCVE));
        rewardManager.updateUserClaimIndex(user1, 1);

        assertEq(usdc.balanceOf(address(this)), 0);

        vm.expectEmit(true, true, true, true);
        emit RewardPaid(user1, _USDC_ADDRESS, 100e6);

        rewardManager.manageRewardsFor(user1);

        assertEq(usdc.balanceOf(address(this)), 100e6);
    }
}
