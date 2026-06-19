// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";
import { MockToken } from "contracts/mocks/MockToken.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

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

    function test_createLockFor_requiresLockingPermissionAndCreditsRecipient()
        public
    {
        address lockingOperator = makeAddr("lockingOperator");
        uint256 amount = 10e18;
        ClaimAction memory action;

        _prepareCVE(lockingOperator, amount);

        vm.startPrank(lockingOperator);
        cve.approve(address(veCVE), amount);
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.createLockFor(user1, amount, false, action, bytes(""), 0);
        vm.stopPrank();

        centralRegistry.addLockingPermissions(lockingOperator);

        uint256 unlockEpoch = veCVE.freshLockEpoch();
        uint256 unlockTime = veCVE.freshLockTimestamp();

        _createLockFor(lockingOperator, user1, amount, false);

        _assertSingleLock(user1, amount, unlockTime);
        _assertPointState(user1, amount, amount);
        _assertUnlockState(user1, unlockEpoch, amount, amount);
        assertEq(veCVE.balanceOf(user1), amount, "recipient veCVE balance");
        assertEq(
            veCVE.balanceOf(lockingOperator),
            0,
            "operator should not receive veCVE"
        );
    }

    function test_increaseAmountAndExtendLockFor_convertsToContinuous()
        public
    {
        address lockingOperator = makeAddr("lockingOperator");
        uint256 amount = 10e18;
        uint256 addedAmount = 5e18;

        centralRegistry.addLockingPermissions(lockingOperator);

        uint256 originalUnlockEpoch = veCVE.freshLockEpoch();
        _createLockFor(lockingOperator, user1, amount, false);

        _increaseLockFor(lockingOperator, user1, addedAmount, 0, true);

        uint256 finalAmount = amount + addedAmount;
        uint256 expectedPoints = finalAmount * veCVE.CL_POINT_MULTIPLIER();

        _assertSingleLock(user1, finalAmount, veCVE.CONTINUOUS_LOCK_VALUE());
        _assertPointState(user1, expectedPoints, expectedPoints);
        _assertUnlockState(user1, originalUnlockEpoch, 0, 0);
        assertEq(veCVE.balanceOf(user1), finalAmount, "veCVE balance");
    }

    function test_disableContinuousLock_removesBonusAndSchedulesFreshUnlock()
        public
    {
        uint256 amount = 12e18;

        _createLock(user1, amount, true);

        uint256 unlockEpoch = veCVE.freshLockEpoch();
        uint256 unlockTime = veCVE.freshLockTimestamp();
        ClaimAction memory action;

        vm.prank(user1);
        veCVE.disableContinuousLock(0, action, bytes(""), 0);

        _assertSingleLock(user1, amount, unlockTime);
        _assertPointState(user1, amount, amount);
        _assertUnlockState(user1, unlockEpoch, amount, amount);
        assertEq(veCVE.balanceOf(user1), amount, "veCVE balance");
    }

    function test_combineAllLocksToContinuousClearsUnlockSchedule() public {
        uint256 firstAmount = 10e18;
        uint256 secondAmount = 7e18;

        uint256 unlockEpoch = veCVE.freshLockEpoch();
        _createLock(user1, firstAmount, false);
        _createLock(user1, secondAmount, false);

        ClaimAction memory action;

        vm.prank(user1);
        veCVE.combineAllLocks(true, action, bytes(""), 0);

        uint256 finalAmount = firstAmount + secondAmount;
        uint256 expectedPoints = finalAmount * veCVE.CL_POINT_MULTIPLIER();

        _assertSingleLock(user1, finalAmount, veCVE.CONTINUOUS_LOCK_VALUE());
        _assertPointState(user1, expectedPoints, expectedPoints);
        _assertUnlockState(user1, unlockEpoch, 0, 0);
        assertEq(veCVE.balanceOf(user1), finalAmount, "veCVE balance");
    }

    function test_combineMixedLocksToNonContinuousNormalizesPointsAndUnlocks()
        public
    {
        uint256 firstAmount = 10e18;
        uint256 secondAmount = 7e18;

        uint256 firstUnlockEpoch = veCVE.freshLockEpoch();
        _createLock(user1, firstAmount, false);

        _deliverEpochs(1);

        uint256 terminalUnlockEpoch = veCVE.freshLockEpoch();
        uint256 terminalUnlockTime = veCVE.freshLockTimestamp();
        _createLock(user1, secondAmount, true);

        ClaimAction memory action;

        vm.prank(user1);
        veCVE.combineAllLocks(false, action, bytes(""), 0);

        uint256 finalAmount = firstAmount + secondAmount;

        _assertSingleLock(user1, finalAmount, terminalUnlockTime);
        _assertPointState(user1, finalAmount, finalAmount);
        _assertUnlockState(user1, firstUnlockEpoch, 0, 0);
        _assertUnlockState(
            user1, terminalUnlockEpoch, finalAmount, finalAmount
        );
        assertEq(veCVE.balanceOf(user1), finalAmount, "veCVE balance");
    }

    function test_processExpiredLockWithRelockKeepsLockAndRestoresPoints()
        public
    {
        uint256 amount = 10e18;

        _createLock(user1, amount, false);
        uint256 expiredUnlockEpoch = veCVE.freshLockEpoch();

        _deliverEpochs(expiredUnlockEpoch + 1);

        assertEq(veCVE.chainPoints(), 0, "delivered epoch should age points");

        ClaimAction memory action;

        vm.prank(user1);
        veCVE.processExpiredLock(0, true, true, action, bytes(""), 0);

        uint256 expectedPoints = amount * veCVE.CL_POINT_MULTIPLIER();

        _assertSingleLock(user1, amount, veCVE.CONTINUOUS_LOCK_VALUE());
        _assertPointState(user1, expectedPoints, expectedPoints);
        assertEq(
            veCVE.userUnlocksByEpoch(user1, expiredUnlockEpoch),
            0,
            "expired user unlock schedule"
        );
        assertEq(veCVE.balanceOf(user1), amount, "veCVE balance");
        assertEq(
            rewardManager.userNextClaimIndex(user1),
            expiredUnlockEpoch + 1,
            "claim index"
        );
    }

    function test_processExpiredLockWithoutRelockBurnsAndReturnsCVE() public {
        uint256 amount = 10e18;

        _createLock(user1, amount, false);
        uint256 expiredUnlockEpoch = veCVE.freshLockEpoch();

        _deliverEpochs(expiredUnlockEpoch + 1);

        uint256 userCveBefore = cve.balanceOf(user1);

        ClaimAction memory action;

        vm.prank(user1);
        veCVE.processExpiredLock(0, false, false, action, bytes(""), 0);

        _assertNoLocks(user1);
        _assertPointState(user1, 0, 0);
        assertEq(
            veCVE.userUnlocksByEpoch(user1, expiredUnlockEpoch),
            0,
            "expired user unlock schedule"
        );
        assertEq(veCVE.balanceOf(user1), 0, "veCVE balance");
        assertEq(cve.balanceOf(user1), userCveBefore + amount, "returned CVE");
        assertEq(
            rewardManager.userNextClaimIndex(user1), 0, "claim index reset"
        );
    }

    function test_shutdownProcessExpiredLockForcesExitEvenWhenRelockRequested()
        public
    {
        uint256 amount = 10e18;

        uint256 unlockEpoch = veCVE.freshLockEpoch();
        _createLock(user1, amount, false);

        uint256 userCveBefore = cve.balanceOf(user1);

        veCVE.shutdown();

        ClaimAction memory action = ClaimAction(true, true, true, true);

        vm.prank(user1);
        veCVE.processExpiredLock(0, true, true, action, bytes(""), 0);

        _assertNoLocks(user1);
        _assertPointState(user1, 0, 0);
        _assertUnlockState(user1, unlockEpoch, 0, 0);
        assertEq(veCVE.balanceOf(user1), 0, "veCVE balance");
        assertEq(cve.balanceOf(user1), userCveBefore + amount, "returned CVE");
        assertEq(veCVE.isShutdown(), 2, "shutdown mode");
    }

    function test_earlyExpireLockBurnsAndSplitsPenalty() public {
        uint256 amount = 10e18;
        uint256 penaltyMultiplier = 3000;

        uint256 unlockEpoch = veCVE.freshLockEpoch();
        _createLock(user1, amount, false);

        centralRegistry.setEarlyUnlockPenaltyMultiplier(penaltyMultiplier);

        uint256 penalty = veCVE.getUnlockPenalty(user1, 0);
        uint256 userCveBefore = cve.balanceOf(user1);
        address dao = centralRegistry.daoAddress();
        uint256 daoCveBefore = cve.balanceOf(dao);

        ClaimAction memory action;

        vm.prank(user1);
        veCVE.earlyExpireLock(0, action, bytes(""), 0);

        _assertNoLocks(user1);
        _assertPointState(user1, 0, 0);
        _assertUnlockState(user1, unlockEpoch, 0, 0);
        assertEq(veCVE.balanceOf(user1), 0, "veCVE balance");
        assertEq(
            cve.balanceOf(user1),
            userCveBefore + amount - penalty,
            "returned CVE after penalty"
        );
        assertEq(cve.balanceOf(dao), daoCveBefore + penalty, "dao penalty");
        assertGt(penalty, 0, "penalty should be active");
    }

    function test_bridgeLockRemovesLocalPointsUnlocksAndLockedCVE() public {
        uint256 amount = 10e18;
        uint256 dstChainId = 42161;
        uint16 wormholeChainId = 23;
        uint256 gasLimit = 750_000;

        MockWormholeRelayer relayer = new MockWormholeRelayer();
        MockWormholeCore wormholeCore = new MockWormholeCore();

        centralRegistry.setCrosschainRelayer(address(relayer));
        centralRegistry.setCrosschainCore(address(wormholeCore));
        _addTestChain(dstChainId, wormholeChainId, address(relayer));

        uint256 unlockEpoch = veCVE.freshLockEpoch();
        _createLock(user1, amount, false);

        VeCVE.BridgeData memory bridgeData = VeCVE.BridgeData({
            dstChainId: dstChainId, gasLimit: gasLimit, continuousLock: true
        });
        ClaimAction memory action;

        vm.prank(user1);
        veCVE.bridgeLock(0, bridgeData, action, bytes(""), 0);

        _assertNoLocks(user1);
        _assertPointState(user1, 0, 0);
        _assertUnlockState(user1, unlockEpoch, 0, 0);
        assertEq(veCVE.balanceOf(user1), 0, "veCVE balance");
        assertEq(cve.balanceOf(address(veCVE)), 0, "locked CVE residue");
        assertEq(relayer.lastTargetChain(), wormholeChainId, "target chain");
        assertEq(relayer.lastTargetAddress(), address(messagingHub), "target");
        assertEq(relayer.lastGasLimit(), gasLimit, "gas limit");
        assertEq(
            keccak256(relayer.lastPayload()),
            keccak256(abi.encode(4, user1, amount, true)),
            "bridge payload"
        );
    }

    function test_userExitDoesNotPerturbOtherUserPointsOrUnlocks() public {
        uint256 user1Amount = 10e18;
        uint256 user2Amount = 11e18;
        uint256 penaltyMultiplier = 3000;

        uint256 unlockEpoch = veCVE.freshLockEpoch();
        _createLock(user1, user1Amount, false);
        _createLock(user2, user2Amount, false);

        centralRegistry.setEarlyUnlockPenaltyMultiplier(penaltyMultiplier);

        ClaimAction memory action;

        vm.prank(user1);
        veCVE.earlyExpireLock(0, action, bytes(""), 0);

        _assertNoLocks(user1);
        _assertSingleLock(user2, user2Amount, veCVE.freshLockTimestamp());
        assertEq(veCVE.userPoints(user1), 0, "user1 points");
        assertEq(veCVE.userPoints(user2), user2Amount, "user2 points");
        assertEq(veCVE.chainPoints(), user2Amount, "chain points");
        assertEq(
            veCVE.userUnlocksByEpoch(user1, unlockEpoch), 0, "user1 unlocks"
        );
        assertEq(
            veCVE.userUnlocksByEpoch(user2, unlockEpoch),
            user2Amount,
            "user2 unlocks"
        );
        assertEq(
            veCVE.chainUnlocksByEpoch(unlockEpoch),
            user2Amount,
            "chain unlocks"
        );
        assertEq(veCVE.balanceOf(user2), user2Amount, "user2 veCVE balance");
    }

    function test_rescueTokenRequiresDaoAndCannotRescueCVE() public {
        MockToken rescueToken = new MockToken("Rescue", "RSC", 18);
        uint256 amount = 123e18;

        rescueToken.transfer(address(veCVE), amount);

        vm.prank(user1);
        vm.expectRevert(VeCVE.VeCVE__Unauthorized.selector);
        veCVE.rescueToken(address(rescueToken), amount);

        vm.expectRevert(VeCVE.VeCVE__NonTransferrable.selector);
        veCVE.rescueToken(address(cve), 0);

        address dao = centralRegistry.daoAddress();
        uint256 daoBalanceBefore = rescueToken.balanceOf(dao);

        veCVE.rescueToken(address(rescueToken), 0);

        assertEq(
            rescueToken.balanceOf(address(veCVE)),
            0,
            "veCVE rescue token residue"
        );
        assertEq(
            rescueToken.balanceOf(dao),
            daoBalanceBefore + amount,
            "dao rescue balance"
        );
    }

    function _createLock(address user, uint256 amount, bool continuous)
        internal
    {
        ClaimAction memory action;

        _prepareCVE(user, amount);

        vm.startPrank(user);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(amount, continuous, action, bytes(""), 0);
        vm.stopPrank();
    }

    function _createLockFor(
        address lockingOperator,
        address recipient,
        uint256 amount,
        bool continuous
    ) internal {
        ClaimAction memory action;

        _prepareCVE(lockingOperator, amount);

        vm.startPrank(lockingOperator);
        cve.approve(address(veCVE), amount);
        veCVE.createLockFor(
            recipient, amount, continuous, action, bytes(""), 0
        );
        vm.stopPrank();
    }

    function _increaseLockFor(
        address lockingOperator,
        address recipient,
        uint256 amount,
        uint256 lockIndex,
        bool continuous
    ) internal {
        ClaimAction memory action;

        _prepareCVE(lockingOperator, amount);

        vm.startPrank(lockingOperator);
        cve.approve(address(veCVE), amount);
        veCVE.increaseAmountAndExtendLockFor(
            recipient, amount, lockIndex, continuous, action, bytes(""), 0
        );
        vm.stopPrank();
    }

    function _deliverEpochs(uint256 numEpochs) internal {
        for (uint256 i; i < numEpochs; ++i) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(0);
            _skipEpochDuration(1);
        }
    }

    function _addTestChain(
        uint256 chainId,
        uint16 messagingChainId,
        address relayer
    ) internal {
        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = messagingChainId;
        config.domain = 3;
        config.messagingHub = address(messagingHub);
        config.votingHub = address(votingHub);
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = relayer;

        centralRegistry.addChain(chainId, config);
    }

    function _assertSingleLock(
        address user,
        uint256 expectedAmount,
        uint256 expectedUnlockTime
    ) internal view {
        (uint256[] memory lockAmounts, uint256[] memory lockTimestamps) =
            veCVE.queryUserLocks(user);

        assertEq(lockAmounts.length, 1, "lock count");
        assertEq(lockTimestamps.length, 1, "timestamp count");
        assertEq(lockAmounts[0], expectedAmount, "lock amount");
        assertEq(lockTimestamps[0], expectedUnlockTime, "unlock time");
    }

    function _assertNoLocks(address user) internal view {
        (uint256[] memory lockAmounts, uint256[] memory lockTimestamps) =
            veCVE.queryUserLocks(user);

        assertEq(lockAmounts.length, 0, "lock count");
        assertEq(lockTimestamps.length, 0, "timestamp count");
    }

    function _assertPointState(
        address user,
        uint256 expectedUserPoints,
        uint256 expectedChainPoints
    ) internal view {
        assertEq(veCVE.userPoints(user), expectedUserPoints, "user points");
        assertEq(veCVE.chainPoints(), expectedChainPoints, "chain points");
    }

    function _assertUnlockState(
        address user,
        uint256 epoch,
        uint256 expectedUserUnlocks,
        uint256 expectedChainUnlocks
    ) internal view {
        assertEq(
            veCVE.userUnlocksByEpoch(user, epoch),
            expectedUserUnlocks,
            "user unlocks"
        );
        assertEq(
            veCVE.chainUnlocksByEpoch(epoch),
            expectedChainUnlocks,
            "chain unlocks"
        );
    }
}

contract MockWormholeCore {
    function messageFee() external pure returns (uint256) {
        return 0;
    }
}

contract MockWormholeRelayer {
    uint16 public lastTargetChain;
    address public lastTargetAddress;
    bytes public lastPayload;
    uint256 public lastGasLimit;

    function quoteEVMDeliveryPrice(uint16, uint256, uint256)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256,
        uint256 gasLimit,
        uint16,
        address
    ) external payable returns (uint64) {
        lastTargetChain = targetChain;
        lastTargetAddress = targetAddress;
        lastPayload = payload;
        lastGasLimit = gasLimit;

        return 1;
    }
}
