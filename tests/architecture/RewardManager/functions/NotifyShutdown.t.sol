// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";

contract NotifyShutdownTest is TestBaseRewardManager {
    function test_notifyShutdown_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.notifyShutdown();
    }

    function test_notifyShutdown_success_fromVeCVE() public {
        assertEq(rewardManager.isShutdown(), 1);

        vm.prank(address(rewardManager.veCVE()));
        rewardManager.notifyShutdown();

        assertEq(rewardManager.isShutdown(), 2);
    }

    function test_notifyShutdown_success() public {
        assertEq(rewardManager.isShutdown(), 1);

        rewardManager.notifyShutdown();

        assertEq(rewardManager.isShutdown(), 2);
    }
}
