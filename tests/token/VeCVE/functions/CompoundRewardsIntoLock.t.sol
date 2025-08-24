// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract CompoundRewardsIntoLockTest is TestBaseVeCVE {
    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(rewardManager), 10000e6);
        _prepareCVE(address(rewardManager), 30e18);
        _prepareCVE(user1, 100e18);

        _skipRestrictionDuration();

        vm.prank(address(rewardManager));
        cve.approve(address(veCVE), 30e18);

        vm.startPrank(user1);

        cve.approve(address(veCVE), 100e18);
        veCVE.createLock(50e18, false, action, "", 0);

        vm.stopPrank();
    }

    function test_compoundRewardsIntoLock_fail_whenCallerIsNotRewardManager(
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public {
        vm.expectRevert(VeCVE.VeCVE__Unauthorized.selector);
        veCVE.compoundRewardsIntoLock(
            user1,
            30e18,
            0,
            isFreshLock,
            isFreshLockContinuous
        );
    }

    function test_compoundRewardsIntoLock_fail_whenVeCVEShutdown(
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public {
        veCVE.shutdown();

        vm.prank(address(rewardManager));

        vm.expectRevert(VeCVE.VeCVE__VeCVEShutdown.selector);
        veCVE.compoundRewardsIntoLock(
            user1,
            30e18,
            0,
            isFreshLock,
            isFreshLockContinuous
        );
    }

    function test_compoundRewardsIntoLock_fail_whenAmountIsZero(
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public {
        vm.prank(address(rewardManager));

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.compoundRewardsIntoLock(
            user1,
            0,
            0,
            isFreshLock,
            isFreshLockContinuous
        );
    }

    function test_compoundRewardsIntoLock_fail_whenLockIndexIsInvalid(
        bool isFreshLockContinuous
    ) public {
        vm.prank(address(rewardManager));

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.compoundRewardsIntoLock(
            user1,
            30e18,
            1,
            false,
            isFreshLockContinuous
        );
    }

    function test_compoundRewardsIntoLock_fail_whenUnlockTimestampIsExpired(
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public {
        (, uint40 unlockTime) = veCVE.userLocks(user1, 0);

        for (
            uint256 i = 0;
            i <= (unlockTime - block.timestamp) / veCVE.EPOCH_DURATION();
            i++
        ) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        vm.warp(unlockTime + 1);

        _skipRestrictionDuration();

        vm.prank(address(rewardManager));

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.compoundRewardsIntoLock(
            user1,
            30e18,
            0,
            isFreshLock,
            isFreshLockContinuous
        );
    }

    function test_compoundRewardsIntoLock_success_withContinuousLock(
        bool isFreshLock
    ) public {
        vm.prank(address(rewardManager));
        veCVE.compoundRewardsIntoLock(user1, 30e18, 0, isFreshLock, true);

        (, uint40 unlockTime) = veCVE.userLocks(user1, 0);

        if (isFreshLock) {
            assertEq(
                unlockTime,
                centralRegistry.genesisEpoch() +
                    (veCVE.currentEpoch(block.timestamp) *
                        veCVE.EPOCH_DURATION()) +
                    veCVE.LOCK_DURATION()
            );
        } else {
            assertEq(unlockTime, veCVE.CONTINUOUS_LOCK_VALUE());
        }
    }

    function test_compoundRewardsIntoLock_success_withDiscontinuousLock(
        bool isFreshLock
    ) public {
        vm.prank(address(rewardManager));
        veCVE.compoundRewardsIntoLock(user1, 30e18, 0, isFreshLock, false);

        (, uint40 unlockTime) = veCVE.userLocks(user1, 0);
        assertEq(unlockTime, veCVE.freshLockTimestamp());
    }
}
