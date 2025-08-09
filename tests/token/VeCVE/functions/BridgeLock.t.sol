// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { VeCVE } from "contracts/token/VeCVE.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";

contract BridgeLockTest is TestBaseVeCVE {
    VeCVE.BridgeData public bridgeData = VeCVE.BridgeData(42161, 0, true);

    function setUp() public override {
        super.setUp();

        // Support chainId 42161.
        ChainConfig memory config;
        config.isSupported = 2;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHub);
        config.votingHub = address(votingHub);
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        centralRegistry.addChain(42161, config);

        _prepareUSDC(address(rewardManager), 10000e6);
        _prepareCVE(address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        _skipRestrictionDuration();

        veCVE.createLock(30e18, false, rewardsData, "", 0);
        veCVE.createLock(30e18, true, rewardsData, "", 0);
    }

    function test_bridgeLock_fail_whenVeCVEIsShutdown(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        veCVE.shutdown();

        vm.expectRevert(VeCVE.VeCVE__VeCVEShutdown.selector);
        veCVE.bridgeLock(0, bridgeData, rewardsData, "", 0);
    }

    function test_bridgeLock_fail_whenLockIndexExceeds(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.bridgeLock(2, bridgeData, rewardsData, "", 0);
    }

    function test_bridgeLock_fail_whenLockIsExpired(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

        for (
            uint256 i = 0;
            i <= (unlockTime - block.timestamp) / veCVE.epochDuration();
            i++
        ) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        vm.warp(unlockTime);

        _skipRestrictionDuration();

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.bridgeLock(0, bridgeData, rewardsData, "", 0);
    }

    function test_bridgeLock_fail_whenNativeTokenIsNotEnoughToCoverFee(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

        vm.expectRevert();
        veCVE.bridgeLock{ value: messageFee - 1 }(
            1,
            bridgeData,
            rewardsData,
            "",
            0
        );
    }

    function test_bridgeLock_fail_whenDestinationChainIsNotRegistered(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);

        bridgeData.dstChainId = 42162;

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        veCVE.bridgeLock{ value: messageFee }(
            0,
            bridgeData,
            rewardsData,
            "",
            0
        );
    }

    function test_bridgeLock_fail_whenPostEpochRestriction(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);

        vm.warp(veCVE.nextEpochStartTime() - veCVE.epochDuration());

        vm.expectRevert(VeCVE.VeCVE__PostEpochRestriction.selector);
        veCVE.bridgeLock{ value: messageFee }(
            0,
            bridgeData,
            rewardsData,
            "",
            0
        );
    }

    function test_bridgeLock_fail_whenPreEpochRestriction(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);

        vm.warp(veCVE.nextEpochStartTime() - 1);

        vm.expectRevert(VeCVE.VeCVE__PreEpochRestriction.selector);
        veCVE.bridgeLock{ value: messageFee }(
            0,
            bridgeData,
            rewardsData,
            "",
            0
        );
    }

    function test_bridgeLock_success(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);

        uint256 veCVEBalance = veCVE.balanceOf(address(this));
        uint256 cveBalance = cve.balanceOf(address(this));
        uint256 cveTotalSupply = cve.totalSupply();

        veCVE.bridgeLock{ value: messageFee }(
            0,
            bridgeData,
            rewardsData,
            "",
            0
        );

        assertEq(veCVE.balanceOf(address(this)), 30e18);
        assertEq(cve.balanceOf(address(this)), cveBalance);
        assertEq(cve.totalSupply(), cveTotalSupply - veCVEBalance + 30e18);

        veCVE.bridgeLock{ value: messageFee }(
            0,
            bridgeData,
            rewardsData,
            "",
            0
        );
    }
}
