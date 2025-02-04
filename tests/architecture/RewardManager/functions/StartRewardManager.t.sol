// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract StartRewardManagerTest is TestBaseRewardManager {
    function setUp() public override {
        super.setUp();

        rewardManager = new RewardManager(
            ICentralRegistry(address(centralRegistry))
        );
    }

    function test_startRewardManager_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.startRewardManager();
    }

    function test_startRewardManager_fail_whenRewardManagerIsAlreadyStarted()
        public
    {
        rewardManager.startRewardManager();

        vm.expectRevert(
            RewardManager.RewardManager__RewardManagerIsAlreadyStarted.selector
        );
        rewardManager.startRewardManager();
    }

    function test_startRewardManager_success() public {
        assertEq(rewardManager.rewardManagerStarted(), 1);
        assertEq(address(rewardManager.veCVE()), address(0));

        rewardManager.startRewardManager();

        assertEq(rewardManager.rewardManagerStarted(), 2);
        assertEq(address(rewardManager.veCVE()), centralRegistry.veCVE());
    }
}
