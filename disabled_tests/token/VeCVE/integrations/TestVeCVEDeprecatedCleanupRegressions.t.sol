// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestVeCVEDeprecatedCleanupRegressions is TestBaseMarketIsolated {
    function setUp() public override {
        _fork(23263997);
        _deployBaseContracts();
        _skipRestrictionDuration();
    }

    function test_overrideRecordEpochRewards_updatesChainPointsForUnlockEpoch()
        public
    {
        uint256 amount = 100e18;
        ClaimAction memory action;

        _prepareCVE(user1, amount);
        vm.startPrank(user1);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(amount, false, action, bytes(""), 0);
        vm.stopPrank();

        uint256 unlockEpoch = veCVE.freshLockEpoch();

        assertEq(veCVE.chainPoints(), amount);
        assertEq(veCVE.chainUnlocksByEpoch(unlockEpoch), amount);

        _recordEpochRewards(unlockEpoch, 0);
        vm.warp(
            centralRegistry.genesisEpoch() +
                (unlockEpoch * rewardManager.EPOCH_DURATION()) +
                1 hours
        );

        rewardManager.overrideRecordEpochRewards();

        assertEq(rewardManager.nextEpochToDeliver(), unlockEpoch + 1);
        assertEq(veCVE.chainPoints(), 0);
    }

    function test_processExpiredLockBeforeRewardDeliveryClearsExpiredPoints()
        public
    {
        uint256 amount = 100e18;
        ClaimAction memory action;

        _prepareCVE(user1, amount);
        vm.startPrank(user1);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(amount, false, action, bytes(""), 0);
        vm.stopPrank();

        uint256 unlockEpoch = veCVE.freshLockEpoch();

        _recordEpochRewards(unlockEpoch, 0);
        vm.warp(
            centralRegistry.genesisEpoch() +
                (unlockEpoch * rewardManager.EPOCH_DURATION()) +
                veCVE.RESTRICTION_DURATION() +
                1
        );

        vm.prank(user1);
        veCVE.processExpiredLock(0, false, false, action, bytes(""), 0);

        (uint256[] memory lockAmounts,) = veCVE.queryUserLocks(user1);

        assertEq(lockAmounts.length, 0);
        assertEq(veCVE.userPoints(user1), 0);
        assertEq(veCVE.chainPoints(), 0);
        assertEq(veCVE.userUnlocksByEpoch(user1, unlockEpoch), 0);
        assertEq(veCVE.chainUnlocksByEpoch(unlockEpoch), 0);
        assertEq(cve.balanceOf(user1), amount);
    }

    function test_processExpiredRelockBeforeRewardDeliveryMovesUnlockSchedule()
        public
    {
        uint256 amount = 100e18;
        ClaimAction memory action;

        _prepareCVE(user1, amount);
        vm.startPrank(user1);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(amount, false, action, bytes(""), 0);
        vm.stopPrank();

        uint256 oldUnlockEpoch = veCVE.freshLockEpoch();

        _recordEpochRewards(oldUnlockEpoch, 0);
        vm.warp(
            centralRegistry.genesisEpoch() +
                (oldUnlockEpoch * rewardManager.EPOCH_DURATION()) +
                veCVE.RESTRICTION_DURATION() +
                1
        );

        uint256 newUnlockEpoch = veCVE.freshLockEpoch();

        vm.prank(user1);
        veCVE.processExpiredLock(0, true, false, action, bytes(""), 0);

        (uint256[] memory lockAmounts,) = veCVE.queryUserLocks(user1);

        assertEq(lockAmounts.length, 1);
        assertEq(lockAmounts[0], amount);
        assertEq(veCVE.userPoints(user1), amount);
        assertEq(veCVE.chainPoints(), amount);
        assertEq(veCVE.userUnlocksByEpoch(user1, oldUnlockEpoch), 0);
        assertEq(veCVE.chainUnlocksByEpoch(oldUnlockEpoch), 0);
        assertEq(veCVE.userUnlocksByEpoch(user1, newUnlockEpoch), amount);
        assertEq(veCVE.chainUnlocksByEpoch(newUnlockEpoch), amount);
    }
}
