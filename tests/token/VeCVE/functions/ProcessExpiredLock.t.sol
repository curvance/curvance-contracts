// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract ProcessExpiredLockTest is TestBaseVeCVE {
    event Unlocked(address indexed user, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        deal(_USDC_ADDRESS, address(rewardManager), 10000e18);
        deal(address(cve), address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.protocolMessagingHub());
            rewardManager.recordEpochRewards(_ONE);
        }

        skip(veCVE.RESTRICTION_DURATION() + 1);

        veCVE.createLock(30e18, false, rewardsData, "", 0);

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

        for (
            uint256 i = 0;
            i <= (unlockTime - block.timestamp) / veCVE.EPOCH_DURATION();
            i++
        ) {
            vm.prank(centralRegistry.protocolMessagingHub());
            rewardManager.recordEpochRewards(_ONE);
        }
    }

    function test_processExpiredLock_fail_whenLockIndexExceeds() public {
        // no need to set rewardsData because it will revert before
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.processExpiredLock(1, false, false, rewardsData, "", 0);
    }

    function test_processExpiredLock_fail_whenLockIsNotExpired() public {
        // no need to set rewardsData because it will revert before
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.processExpiredLock(0, false, false, rewardsData, "", 0);
    }

    function test_processExpiredLock_success_withContinuousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        skip(veCVE.RESTRICTION_DURATION() + 1);

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(0, false, true, rewardsData, "", 0);
    }

    function test_processExpiredLock_success_withDiscontinuousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        skip(veCVE.RESTRICTION_DURATION() + 1);

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(0, false, false, rewardsData, "", 0);
    }

    // cover L575
    function test_processExpiredLock_success_withDiscontinuousLock_withContinuousRelock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        (uint216 amount, uint40 unlockTime) = veCVE.userLocks(
            address(this),
            0
        );
        vm.warp(unlockTime);

        skip(veCVE.RESTRICTION_DURATION() + 1);

        // Index 0, relock = true, continuous lock mode = true
        veCVE.processExpiredLock(0, true, true, rewardsData, "", 0);

        // lockIndex 0 is updated to new timestamp
        (uint216 amount2, uint40 unlockTime2) = veCVE.userLocks(
            address(this),
            0
        );
        assertGt(unlockTime2, unlockTime);
        assertEq(unlockTime2, veCVE.CONTINUOUS_LOCK_VALUE());
        assertEq(amount2, amount);
    }

    // cover L580
    function test_processExpiredLock_success_withDiscontinuousLock_withDiscontinuousRelock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        (uint216 amount, uint40 unlockTime) = veCVE.userLocks(
            address(this),
            0
        );
        vm.warp(unlockTime);

        skip(veCVE.RESTRICTION_DURATION() + 1);

        // Index 0, relock = true, continuous lock mode = false
        veCVE.processExpiredLock(0, true, false, rewardsData, "", 0);

        // lockIndex 0 is updated to new timestamp
        (uint216 amount2, uint40 unlockTime2) = veCVE.userLocks(
            address(this),
            0
        );
        assertGt(unlockTime2, unlockTime);
        assertEq(unlockTime2, veCVE.freshLockTimestamp());
        assertEq(amount2, amount);
    }

    // cover L566
    function test_processExpiredLock_success_withDiscontinuousLock_withRelock_duringShutdown(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        skip(veCVE.RESTRICTION_DURATION() + 1);

        veCVE.shutdown();

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(
            0,
            true, // relock but it will be ignored because of shutdown
            false,
            rewardsData,
            "",
            0
        );
    }

    // cover L1117
    function test_processExpiredLock_sucess_withoutRelock_notLastIndex()
        public
    {
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        skip(veCVE.RESTRICTION_DURATION() + 1);

        veCVE.createLock(30e18, false, rewardsData, "", 0);
        (, uint40 unlockTime2) = veCVE.userLocks(address(this), 1);
        assertGt(unlockTime2, unlockTime);

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(0, false, false, rewardsData, "", 0);

        (, unlockTime) = veCVE.userLocks(address(this), 0);
        assertEq(unlockTime, unlockTime2);

        // except revert for invalid index because expired lock is removed
        vm.expectRevert();
        (, unlockTime) = veCVE.userLocks(address(this), 1);
    }
}
