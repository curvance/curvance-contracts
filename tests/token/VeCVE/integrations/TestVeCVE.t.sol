// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";

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

        _skipRestrictionDuration();

        centralRegistry.transferDaoOwnership(user1);
    }

    function test_createLockBeforeGenesisStartTime() public {
        uint256 amount = 2e18;
        uint256 penaltyMultiplier = 5000;
        rewardsData = RewardsData(false, true, true, true);

        centralRegistry.setEarlyUnlockPenaltyMultiplier(penaltyMultiplier);

        (uint256[] memory lockAmounts, uint256[] memory lockTimestamps) = veCVE
            .queryUserLocks(address(this));

        assertEq(lockAmounts.length, 0);
        assertEq(lockTimestamps.length, 0);
        assertEq(veCVE.getVotes(address(this)), 0);

        vm.expectEmit(true, true, true, true, address(veCVE));
        emit Locked(address(this), amount);

        vm.warp(centralRegistry.genesisEpoch() - 13 hours);
        veCVE.createLock(amount, true, rewardsData, "", 0);

        assertEq(cve.balanceOf(address(this)), 100e18 - amount);
        assertEq(veCVE.balanceOf(address(this)), amount);
    }

    function test_createLockWithContinuousLock_earlyExpireLock_success_fuzzed(
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

        assertEq(penaltyAmount, prevPenaltyAmount);

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
            centralRegistry.genesisEpoch() +
                (veCVE.currentEpoch(timestamp) * veCVE.epochDuration()) +
                veCVE.lockDuration()
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

    function test_lockAndUnlockInSameEpoch()
        public
        setRewardsData(false, false, false)
    {
        // 1. config poc env
        deal(_USDC_ADDRESS, address(rewardManager), 10000e6);
        vm.warp(centralRegistry.genesisEpoch());

        _skipRestrictionDuration();
        _recordEpochRewards(1, 1e6 * _ONE);

        assertEq(rewardManager.nextEpochToDeliver(), 1);

        address user00 = address(0xACC00);
        deal(address(cve), user00, 100 * 1e18);
        vm.prank(user00);
        cve.approve(address(veCVE), type(uint256).max);

        // 2. user00 create the first lock
        vm.prank(user00);
        veCVE.createLock(1e18, false, rewardsData, "", 0);
        assertEq(veCVE.userPoints(user00), 1e18);
        assertEq(veCVE.userUnlocksByEpoch(user00, 26), 0);

        // 3. 26 epoch passed
        _recordEpochRewards(26, 1e6 * _ONE);

        assertEq(rewardManager.nextEpochToDeliver(), 27);

        // 4. user00 close the first lock and create the second lock within the same epoch
        vm.startPrank(user00);
        veCVE.processExpiredLock(0, false, false, rewardsData, "", 0);
        assertEq(veCVE.userPoints(user00), 1e18);
        veCVE.createLock(1e18, false, rewardsData, "", 0);
        assertEq(veCVE.userPoints(user00), 2e18);
        vm.stopPrank();

        // 5. 1 epoch has passed, the user claim the reward and trigger the bug.
        //    As a result, the user's points are repeatedly subtracted and become 0.
        _recordEpochRewards(1, 1e6 * _ONE);

        assertEq(rewardManager.nextEpochToDeliver(), 28);
        assertEq(veCVE.userPoints(user00), 2e18);
        vm.prank(user00);
        rewardManager.claimRewards(rewardsData, "", 0); // Trigger claim to offset points to what should be 0
        assertEq(veCVE.userPoints(user00), 1e18);
    }
}
