// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract IncreaseAmountAndExtendLockForTest is TestBaseVeCVE {
    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(rewardManager), 10000e6);
        _prepareCVE(address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        centralRegistry.addLockingPermissions(address(this));

        _skipRestrictionDuration();

        veCVE.createLockFor(address(1), 50e18, false, action, "", 0);

        centralRegistry.removeLockingPermissions(address(this));
    }

    function test_increaseAmountAndExtendLockFor_fail_whenVeCVEShutdown()
        public
    {
        veCVE.shutdown();

        vm.expectRevert(VeCVE.VeCVE__VeCVEShutdown.selector);
        veCVE.increaseAmountAndExtendLockFor(
            address(1),
            30e18,
            0,
            true,
            action,
            "",
            0
        );
    }

    function test_increaseAmountAndExtendLockFor_fail_whenAmountIsZero()
        public
    {
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.increaseAmountAndExtendLockFor(
            address(1),
            0,
            0,
            true,
            action,
            "",
            0
        );
    }

    function test_lockFor_fail_whenRewardManagerIsNotApproved() public {
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.increaseAmountAndExtendLockFor(
            address(1),
            30e18,
            0,
            true,
            action,
            "",
            0
        );
    }

    function test_increaseAmountAndExtendLockFor_fail_whenLockIndexIsInvalid(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        centralRegistry.addLockingPermissions(address(this));

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.increaseAmountAndExtendLockFor(
            address(1),
            30e18,
            1,
            true,
            action,
            "",
            0
        );
    }

    function test_increaseAmountAndExtendLockFor_fail_whenUnlockTimestampIsExpired(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        centralRegistry.addLockingPermissions(address(this));

        (, uint40 unlockTime) = veCVE.userLocks(address(1), 0);

        for (
            uint256 i = 0;
            i <= (unlockTime - block.timestamp) / veCVE.epochDuration();
            i++
        ) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        vm.warp(unlockTime + 1);

        _skipRestrictionDuration();

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.increaseAmountAndExtendLockFor(
            address(1),
            30e18,
            0,
            true,
            action,
            "",
            0
        );
    }

    function test_increaseAmountAndExtendLockFor_success_withContinuousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        centralRegistry.addLockingPermissions(address(this));

        veCVE.increaseAmountAndExtendLockFor(
            address(1),
            30e18,
            0,
            true,
            action,
            "",
            0
        );

        (, uint40 unlockTime) = veCVE.userLocks(address(1), 0);
        assertEq(unlockTime, veCVE.CONTINUOUS_LOCK_VALUE());
    }

    function test_increaseAmountAndExtendLockFor_success_withDiscontinuousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        centralRegistry.addLockingPermissions(address(this));

        veCVE.increaseAmountAndExtendLockFor(
            address(1),
            30e18,
            0,
            false,
            action,
            "",
            0
        );

        (, uint40 unlockTime) = veCVE.userLocks(address(1), 0);
        assertEq(unlockTime, veCVE.freshLockTimestamp());
    }

    function test_increaseAmountAndExtendLockFor_fail_startContinuousLock()
        public
    {
        centralRegistry.addLockingPermissions(address(this));

        veCVE.createLockFor(address(2), 10e18, true, action, "", 0);

        // cannot extned a continuous lock with a non-continuous lock
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.increaseAmountAndExtendLockFor(
            address(2),
            1e18,
            0,
            false,
            action,
            "",
            0
        );
    }

    // cover L1059
    function test_increaseAmountAndExtendLockFor_success_startContinuousLock()
        public
    {
        centralRegistry.addLockingPermissions(address(this));

        veCVE.createLockFor(address(2), 10e18, true, action, "", 0);

        veCVE.increaseAmountAndExtendLockFor(
            address(2),
            1e18,
            0,
            true,
            action,
            "",
            0
        );

        (uint256 lockAmount, uint40 unlockTime) = veCVE.userLocks(
            address(2),
            0
        );
        assertEq(lockAmount, 11e18);
        assertEq(unlockTime, veCVE.CONTINUOUS_LOCK_VALUE());

        // user points are multiplied by 2
        assertEq(veCVE.userPoints(address(2)), 22e18);
    }
}
