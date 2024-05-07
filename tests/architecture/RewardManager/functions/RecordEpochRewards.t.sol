// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";

contract RecordEpochRewardsTest is TestBaseRewardManager {
    uint256 public nextEpochToDeliver;

    function setUp() public override {
        super.setUp();

        nextEpochToDeliver = rewardManager.nextEpochToDeliver();
    }

    function test_recordEpochRewards_fail_whenCallerIsNotFeeAccumulator()
        public
    {
        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.recordEpochRewards(_ONE);
    }

    function test_recordEpochRewards_success() public {
        assertEq(rewardManager.epochRewardsPerCVE(nextEpochToDeliver), 0);

        vm.prank(centralRegistry.protocolMessagingHub());
        rewardManager.recordEpochRewards(_ONE);

        assertEq(rewardManager.epochRewardsPerCVE(nextEpochToDeliver), _ONE);
        assertEq(rewardManager.nextEpochToDeliver(), nextEpochToDeliver + 1);
    }
}
