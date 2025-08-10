// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract ExtendLockTest is TestBaseVeCVE {
    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(rewardManager), 10000e6);
        _prepareCVE(address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        _skipRestrictionDuration();

        veCVE.createLock(50e18, false, action, "", 0);
    }

    function test_extendLock_fail_whenVeCVEShutdown() public {
        // no need to set action because it will not be called
        veCVE.shutdown();

        vm.expectRevert(VeCVE.VeCVE__VeCVEShutdown.selector);
        veCVE.extendLock(0, true, action, "", 0);
    }

    function test_extendLock_fail_whenLockIndexIsInvalid() public {
        // no need to set action because it will not be called
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.extendLock(1, true, action, "", 0);
    }

    function test_extendLock_fail_whenUnlockTimestampIsExpired() public {
        // no need to set action because it will not be called
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

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

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.extendLock(0, true, action, "", 0);
    }

    function test_extendLock_fail_whenContinuousLock() public {
        // no need to set action because it will not be called
        veCVE.createLock(10e18, true, action, "", 0);

        vm.expectRevert(VeCVE.VeCVE__LockTypeMismatch.selector);
        veCVE.extendLock(1, true, action, "", 0);
    }

    function test_extendLock_success_withContinuousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        veCVE.extendLock(0, true, action, "", 0);

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        assertEq(unlockTime, veCVE.CONTINUOUS_LOCK_VALUE());
    }

    function test_extendLock_success_withDiscontinuousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        veCVE.extendLock(0, false, action, "", 0);

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        assertEq(unlockTime, veCVE.freshLockTimestamp());
    }
}
