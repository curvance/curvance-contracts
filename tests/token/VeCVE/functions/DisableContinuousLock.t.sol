// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract DisableContinuousLockTest is TestBaseVeCVE {
    event RewardPaid(address user, address rewardToken, uint256 amount);

    function setUp() public override {
        super.setUp();

        _prepareCVE(address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        _skipRestrictionDuration();

        veCVE.createLock(50e18, true, action, "", 0);

        _prepareUSDC(address(rewardManager), 200e18);
    }

    function test_disableContinuousLock_fail_whenLockIndexIsInvalid() public {
        // no need to set action because it will not be called
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.disableContinuousLock(1, action, "", 0);
    }

    function test_disableContinuousLock_fail_whenLockIsNotContinousLock(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        veCVE.createLock(30e18, false, action, "", 0);

        vm.expectRevert(VeCVE.VeCVE__LockTypeMismatch.selector);
        veCVE.disableContinuousLock(1, action, "", 0);
    }

    function test_disableContinuousLock_success(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setClaimAction(shouldLock, isFreshLock, isFreshLockContinuous) {
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

        assertEq(veCVE.chainPoints(), 100e18);
        assertEq(veCVE.userPoints(address(this)), 100e18);
        assertEq(veCVE.chainUnlocksByEpoch(veCVE.currentEpoch(unlockTime)), 0);
        assertEq(
            veCVE.userUnlocksByEpoch(
                address(this),
                veCVE.currentEpoch(unlockTime)
            ),
            0
        );

        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.updateUserClaimIndex(address(this), 1);

        _recordEpochRewards(2, 1e6 * _ONE);

        // verify that rewards are delivered
        vm.expectEmit(true, true, true, true, address(rewardManager));
        emit RewardPaid(address(this), _USDC_ADDRESS, 100e6);
        veCVE.disableContinuousLock(0, action, "", 0);

        (, unlockTime) = veCVE.userLocks(address(this), 0);

        assertEq(unlockTime, veCVE.freshLockTimestamp());
        assertEq(veCVE.chainPoints(), 50e18);
        assertEq(veCVE.userPoints(address(this)), 50e18);
        assertEq(
            veCVE.chainUnlocksByEpoch(veCVE.currentEpoch(unlockTime)),
            50e18
        );
        assertEq(
            veCVE.userUnlocksByEpoch(
                address(this),
                veCVE.currentEpoch(unlockTime)
            ),
            50e18
        );
    }
}
