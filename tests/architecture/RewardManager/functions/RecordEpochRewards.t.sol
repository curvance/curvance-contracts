// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";

contract RecordEpochRewardsTest is TestBaseRewardManager {
    uint256 public nextEpochToDeliver;

    function setUp() public override {
        super.setUp();

        nextEpochToDeliver = rewardManager.nextEpochToDeliver();
    }

    function test_recordEpochRewards_fail_whenCallerIsNotMessagingHub()
        public
    {
        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.recordEpochRewards(1e6 * _ONE);
    }

    function test_recordEpochRewards_success() public {
        assertEq(rewardManager.epochRewardsPerPoint(nextEpochToDeliver), 0);

        vm.prank(address(messagingHub));
        rewardManager.recordEpochRewards(1e6 * _ONE);

        assertEq(
            rewardManager.epochRewardsPerPoint(nextEpochToDeliver),
            1e6 * _ONE
        );
        assertEq(rewardManager.nextEpochToDeliver(), nextEpochToDeliver + 1);
    }
}
