// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract EarlyExpireLockTest is TestBaseVeCVE {
    event UnlockedWithPenalty(
        address indexed user,
        uint256 amount,
        uint256 penaltyAmount
    );

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(rewardManager), 100e18);
        _prepareCVE(address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        _skipRestrictionDuration();

        veCVE.createLock(30e18, false, action, "", 0);

        centralRegistry.transferDaoPermissions(user1);
    }

    function test_earlyExpireLock_fail_whenVeCVEIsShutdown(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        veCVE.shutdown();

        vm.expectRevert(VeCVE.VeCVE__VeCVEShutdown.selector);
        veCVE.earlyExpireLock(0, action, "", 0);
    }

    function test_earlyExpireLock_fail_whenLockIndexExceeds() public {
        // no need to set action because it will revert before
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.earlyExpireLock(1, action, "", 0);
    }

    function test_earlyExpireLock_fail_whenEarlyUnlockIsDisabled() public {
        // no need to set action because it will revert before
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.earlyExpireLock(0, action, "", 0);
    }

    function test_earlyExpireLock_fail_expired() public {
        // no need to set action because it will revert before
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

        for (
            uint256 i = 0;
            i <= (unlockTime - block.timestamp) / veCVE.EPOCH_DURATION();
            i++
        ) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        vm.warp(unlockTime);

        _skipRestrictionDuration();

        // cannot early expire expired lock
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.earlyExpireLock(0, action, "", 0);
    }

    function test_earlyExpireLock_success(
        uint16 penaltyMultiplier,
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        penaltyMultiplier = uint16(bound(penaltyMultiplier, 3000, 9000));
        centralRegistry.setEarlyUnlockPenaltyMultiplier(penaltyMultiplier);

        uint256 prevPenaltyAmount = veCVE.getUnlockPenalty(address(this), 0);

        skip(1000000);

        uint256 penaltyAmount = veCVE.getUnlockPenalty(address(this), 0);

        assertLt(penaltyAmount, prevPenaltyAmount);

        uint256 daoCveBalance = cve.balanceOf(centralRegistry.daoAddress());
        uint256 cveBalance = cve.balanceOf(address(this));

        assertGt(penaltyAmount, 0);

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit UnlockedWithPenalty(address(this), 30e18, penaltyAmount);

        veCVE.earlyExpireLock(0, action, "", 0);

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.getUnlockPenalty(address(this), 0);

        assertEq(
            cve.balanceOf(address(this)),
            cveBalance + 30e18 - penaltyAmount
        );
        assertEq(
            cve.balanceOf(centralRegistry.daoAddress()),
            daoCveBalance + penaltyAmount
        );
    }

    function test_getUnlockPenalty_expiredLock() public {
        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime);

        veCVE.getUnlockPenalty(address(this), 0);
    }

    function test_getUnlockPenalty_penaltyZero() public {
        // unlock penalty is 0 by default
        uint256 penalty = veCVE.getUnlockPenalty(address(this), 0);
        assertEq(penalty, 0);
    }

    function test_getUnlockPenalty_fail_invalidIndex() public {
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.getUnlockPenalty(address(this), 111);
    }
}
