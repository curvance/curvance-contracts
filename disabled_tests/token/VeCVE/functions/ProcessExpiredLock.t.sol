// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract ProcessExpiredLockTest is TestBaseVeCVE {
    event Unlocked(address indexed user, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(rewardManager), 10000e18);
        _prepareCVE(address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        _skipRestrictionDuration();

        veCVE.createLock(30e18, false, action, "", 0);
    }

    function test_processExpiredLock_fail_whenLockIndexExceeds() public {
        // no need to set action because it will revert before
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.processExpiredLock(1, false, false, action, "", 0);
    }

    function test_processExpiredLock_fail_whenLockIsNotExpired() public {
        // no need to set action because it will revert before
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.processExpiredLock(0, false, false, action, "", 0);
    }

    function test_processExpiredLock_success_withContinuousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        _recordEpochs();

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        _skipRestrictionDuration();

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(0, false, true, action, "", 0);
    }

    function test_processExpiredLock_success_withDiscontinuousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        _recordEpochs();

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        _skipRestrictionDuration();

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(0, false, false, action, "", 0);
    }

    // cover L575
    function test_processExpiredLock_success_withDiscontinuousLock_withContinuousRelock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        _recordEpochs();

        (uint216 amount, uint40 unlockTime) = veCVE.userLocks(
            address(this),
            0
        );
        vm.warp(unlockTime);

        _skipRestrictionDuration();

        // Index 0, relock = true, continuous lock mode = true
        veCVE.processExpiredLock(0, true, true, action, "", 0);

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
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        _recordEpochs();

        (uint216 amount, uint40 unlockTime) = veCVE.userLocks(
            address(this),
            0
        );
        vm.warp(unlockTime);

        _skipRestrictionDuration();

        // Index 0, relock = true, continuous lock mode = false
        veCVE.processExpiredLock(0, true, false, action, "", 0);

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
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        _recordEpochs();

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        _skipRestrictionDuration();

        veCVE.shutdown();

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(
            0,
            true, // relock but it will be ignored because of shutdown
            false,
            action,
            "",
            0
        );
    }

    function test_processExpiredLock_success_afterShutdownWhenEpochNotDelivered()
        public
    {
        uint256 claimIndex = rewardManager.userNextClaimIndex(address(this));
        while (rewardManager.nextEpochToDeliver() <= claimIndex) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        uint256 finalDeliveredEpoch = rewardManager.nextEpochToDeliver();
        uint256 rewardBalance = usdc.balanceOf(address(this));

        skip(veCVE.EPOCH_DURATION() * 2);

        assertNotEq(
            rewardManager.nextEpochToDeliver(),
            veCVE.currentEpoch(block.timestamp)
        );

        veCVE.shutdown();

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(
            0,
            true,
            true,
            ClaimAction(true, true, true, true),
            "",
            0
        );

        assertEq(veCVE.balanceOf(address(this)), 0);
        assertEq(cve.balanceOf(address(veCVE)), 0);
        assertEq(
            rewardManager.userNextClaimIndex(address(this)),
            finalDeliveredEpoch
        );
        assertGt(rewardManager.userNextClaimIndex(address(this)), claimIndex);
        assertGt(usdc.balanceOf(address(this)), rewardBalance);
    }

    function test_processExpiredLock_success_afterShutdownWhenUnlockEpochDelivered()
        public
    {
        _recordEpochs();

        uint256 claimIndex = rewardManager.userNextClaimIndex(address(this));
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        uint256 unlockEpoch = veCVE.currentEpoch(unlockTime);
        while (rewardManager.nextEpochToDeliver() <= unlockEpoch) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        uint256 finalDeliveredEpoch = rewardManager.nextEpochToDeliver();
        uint256 rewardBalance = usdc.balanceOf(address(this));

        vm.warp(unlockTime + uint40(veCVE.EPOCH_DURATION() * 2));

        assertGt(finalDeliveredEpoch, unlockEpoch);
        assertGt(veCVE.currentEpoch(block.timestamp), finalDeliveredEpoch);

        veCVE.shutdown();

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(
            0,
            false,
            false,
            ClaimAction(true, true, true, true),
            "",
            0
        );

        assertEq(veCVE.balanceOf(address(this)), 0);
        assertEq(cve.balanceOf(address(veCVE)), 0);
        assertEq(
            rewardManager.userNextClaimIndex(address(this)),
            finalDeliveredEpoch
        );
        assertGt(rewardManager.userNextClaimIndex(address(this)), claimIndex);
        assertEq(veCVE.userPoints(address(this)), 0);
        assertEq(
            veCVE.userUnlocksByEpoch(
                address(this),
                unlockEpoch
            ),
            0
        );
        assertGt(usdc.balanceOf(address(this)), rewardBalance);
    }

    function test_processExpiredLock_success_afterShutdownWithContinuousLock()
        public
    {
        veCVE.createLock(
            30e18,
            true,
            ClaimAction(false, false, false, false),
            "",
            0
        );

        uint256 claimIndex = rewardManager.userNextClaimIndex(address(this));
        while (rewardManager.nextEpochToDeliver() <= claimIndex) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        uint256 finalDeliveredEpoch = rewardManager.nextEpochToDeliver();
        uint256 rewardBalance = usdc.balanceOf(address(this));
        uint256 userCveBalance = cve.balanceOf(address(this));
        uint256 userPoints = veCVE.userPoints(address(this));
        uint256 chainPoints = veCVE.chainPoints();
        uint256 continuousPoints = 30e18 * veCVE.CL_POINT_MULTIPLIER();

        veCVE.shutdown();

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(
            1,
            true,
            true,
            ClaimAction(true, true, true, true),
            "",
            0
        );

        (uint256[] memory lockAmounts,) = veCVE.queryUserLocks(address(this));

        assertEq(lockAmounts.length, 1);
        assertEq(lockAmounts[0], 30e18);
        assertEq(veCVE.balanceOf(address(this)), 30e18);
        assertEq(cve.balanceOf(address(veCVE)), 30e18);
        assertEq(cve.balanceOf(address(this)), userCveBalance + 30e18);
        assertEq(veCVE.userPoints(address(this)), userPoints - continuousPoints);
        assertEq(veCVE.chainPoints(), chainPoints - continuousPoints);
        assertEq(
            rewardManager.userNextClaimIndex(address(this)),
            finalDeliveredEpoch
        );
        assertGt(rewardManager.userNextClaimIndex(address(this)), claimIndex);
        assertGt(usdc.balanceOf(address(this)), rewardBalance);
    }

    // cover L1117
    function test_processExpiredLock_success_withoutRelock_notLastIndex()
        public
    {
        _recordEpochs();

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        _skipRestrictionDuration();

        veCVE.createLock(30e18, false, action, "", 0);
        (, uint40 unlockTime2) = veCVE.userLocks(address(this), 1);
        assertGt(unlockTime2, unlockTime);

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Unlocked(address(this), 30e18);

        veCVE.processExpiredLock(0, false, false, action, "", 0);

        (, unlockTime) = veCVE.userLocks(address(this), 0);
        assertEq(unlockTime, unlockTime2);

        // except revert for invalid index because expired lock is removed
        vm.expectRevert();
        (, unlockTime) = veCVE.userLocks(address(this), 1);
    }

    function _recordEpochs() internal {
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

        for (
            uint256 i = 0;
            i <= (unlockTime - block.timestamp) / veCVE.EPOCH_DURATION();
            i++
        ) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }
    }
}
