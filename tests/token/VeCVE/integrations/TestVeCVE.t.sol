// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract TestVeCVE is TestBaseVeCVE {
    event Locked(address indexed user, uint256 amount);
    event UnlockedWithPenalty(
        address indexed user,
        uint256 amount,
        uint256 penaltyAmount
    );

    function setUp() public override {
        super.setUp();

        deal(_USDC_ADDRESS, address(rewardManager), 1000e6);
        deal(address(cve), address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.protocolMessagingHub());
            rewardManager.recordEpochRewards(1e6);
        }

        skip(veCVE.RESTRICTION_DURATION() + 1);

        centralRegistry.transferDaoOwnership(user1);
    }

    function test_createLockWithContinuousLock_earlyExpireLock_revert_fuzzed(
        uint16 penaltyMultiplier,
        uint256 amount,
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        vm.assume(amount > 1e18 && amount <= 100e18);

        penaltyMultiplier = uint16(bound(penaltyMultiplier, 3000, 9000));
        centralRegistry.setEarlyUnlockPenaltyMultiplier(penaltyMultiplier);

        (uint256[] memory lockAmounts, uint256[] memory lockTimestamps) = veCVE
            .queryUserLocks(address(this));

        assertEq(lockAmounts.length, 0);
        assertEq(lockTimestamps.length, 0);
        assertEq(veCVE.getVotes(address(this)), 0);

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Locked(address(this), amount);

        veCVE.createLock(amount, true, rewardsData, "", 0);

        assertEq(cve.balanceOf(address(this)), 100e18 - amount);
        assertEq(veCVE.balanceOf(address(this)), amount);

        (lockAmounts, lockTimestamps) = veCVE.queryUserLocks(address(this));
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

        assertEq(lockAmounts.length, 1);
        assertEq(lockTimestamps.length, 1);
        assertEq(lockAmounts[0], amount);
        assertEq(lockTimestamps[0], unlockTime);
        assertEq(unlockTime, veCVE.CONTINUOUS_LOCK_VALUE());

        assertEq(veCVE.chainPoints(), amount * veCVE.CL_POINT_MULTIPLIER());
        assertEq(
            veCVE.userPoints(address(this)),
            amount * veCVE.CL_POINT_MULTIPLIER()
        );
        assertEq(veCVE.chainUnlocksByEpoch(veCVE.currentEpoch(unlockTime)), 0);

        assertEq(
            veCVE.userUnlocksByEpoch(
                address(this),
                veCVE.currentEpoch(unlockTime)
            ),
            0
        );

        assertEq(veCVE.getVotes(address(this)), amount + amount / 10);

        uint256 prevPenaltyAmount = veCVE.getUnlockPenalty(address(this), 0);

        skip(1000000);

        uint256 penaltyAmount = veCVE.getUnlockPenalty(address(this), 0);

        assertLt(penaltyAmount, prevPenaltyAmount);

        uint256 daoCveBalance = cve.balanceOf(centralRegistry.daoAddress());

        assertGt(penaltyAmount, 0);

        vm.expectRevert(bytes4(keccak256("TransferFailed()")));
        veCVE.earlyExpireLock(0, rewardsData, "", 0);
    }

    function test_createLockWithDiscontinuousLock_earlyExpireLock_success_fuzzed(
        uint16 penaltyMultiplier,
        uint256 amount,
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        vm.assume(amount > 1e18 && amount <= 100e18);

        penaltyMultiplier = uint16(bound(penaltyMultiplier, 3000, 9000));
        centralRegistry.setEarlyUnlockPenaltyMultiplier(penaltyMultiplier);

        (uint256[] memory lockAmounts, uint256[] memory lockTimestamps) = veCVE
            .queryUserLocks(address(this));

        assertEq(lockAmounts.length, 0);
        assertEq(lockTimestamps.length, 0);
        assertEq(veCVE.getVotes(address(this)), 0);

        uint256 timestamp = block.timestamp;

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Locked(address(this), amount);

        veCVE.createLock(amount, false, rewardsData, "", 0);

        assertEq(cve.balanceOf(address(this)), 100e18 - amount);
        assertEq(veCVE.balanceOf(address(this)), amount);

        (lockAmounts, lockTimestamps) = veCVE.queryUserLocks(address(this));
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

        assertEq(lockAmounts.length, 1);
        assertEq(lockTimestamps.length, 1);
        assertEq(lockAmounts[0], amount);
        assertEq(lockTimestamps[0], unlockTime);
        assertEq(
            unlockTime,
            veCVE.genesisEpoch() +
                (veCVE.currentEpoch(timestamp) * veCVE.EPOCH_DURATION()) +
                veCVE.LOCK_DURATION()
        );

        assertEq(veCVE.chainPoints(), amount);
        assertEq(veCVE.userPoints(address(this)), amount);
        assertEq(
            veCVE.chainUnlocksByEpoch(veCVE.currentEpoch(unlockTime)),
            amount
        );
        assertEq(
            veCVE.userUnlocksByEpoch(
                address(this),
                veCVE.currentEpoch(unlockTime)
            ),
            amount
        );

        uint256 prevPenaltyAmount = veCVE.getUnlockPenalty(address(this), 0);

        skip(1000000);

        uint256 penaltyAmount = veCVE.getUnlockPenalty(address(this), 0);

        assertLt(penaltyAmount, prevPenaltyAmount);

        uint256 daoCveBalance = cve.balanceOf(centralRegistry.daoAddress());

        assertGt(penaltyAmount, 0);

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit UnlockedWithPenalty(address(this), amount, penaltyAmount);

        veCVE.earlyExpireLock(0, rewardsData, "", 0);

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.getUnlockPenalty(address(this), 0);

        assertEq(cve.balanceOf(user1), penaltyAmount);
        assertEq(cve.balanceOf(address(this)), 100e18 - penaltyAmount);
        assertEq(
            cve.balanceOf(centralRegistry.daoAddress()),
            daoCveBalance + penaltyAmount
        );
    }
}
