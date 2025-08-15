// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";

contract OverrideRecordEpochRewardsTest is TestBaseRewardManager {
    uint256 public nextEpochToDeliver;

    function setUp() public override {
        super.setUp();

        nextEpochToDeliver = rewardManager.nextEpochToDeliver();
    }

    function test_overrideRecordEpochRewards_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(user1);

        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.overrideRecordEpochRewards();
    }

    function test_overrideRecordEpochRewards_fail_whenOverrideUnavailable()
        public
    {
        vm.expectRevert(
            RewardManager
                .RewardManager__EpochDeliveryOverrideUnavailable
                .selector
        );
        rewardManager.overrideRecordEpochRewards();
    }

    function test_overrideRecordEpochRewards_success() public {
        vm.warp(
            centralRegistry.genesisEpoch() +
                (nextEpochToDeliver * rewardManager.EPOCH_DURATION()) +
                1 hours
        );

        assertEq(rewardManager.epochRewardsPerPoint(nextEpochToDeliver), 0);

        rewardManager.overrideRecordEpochRewards();

        assertEq(rewardManager.epochRewardsPerPoint(nextEpochToDeliver), 0);
        assertEq(rewardManager.nextEpochToDeliver(), nextEpochToDeliver + 1);
    }
}
