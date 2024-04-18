// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { ITokenBridge } from "contracts/interfaces/external/wormhole/ITokenBridge.sol";

contract BridgeLockTest is TestBaseVeCVE {
    ITokenBridge public tokenBridge = ITokenBridge(_TOKEN_BRIDGE);
    VeCVE.BridgeData public bridgeData = VeCVE.BridgeData(42161, 0, true);

    function setUp() public override {
        super.setUp();

        centralRegistry.addChainSupport(
            address(this),
            address(protocolMessagingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            1,
            1,
            23
        );

        deal(_USDC_ADDRESS, address(cveLocker), 10000e6);
        deal(address(cve), address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        vm.prank(centralRegistry.protocolMessagingHub());
        cveLocker.recordEpochRewards(1e6);

        skip(veCVE.RESTRICTION_DURATION() + 1);

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
            i <= (unlockTime - block.timestamp) / veCVE.EPOCH_DURATION();
            i++
        ) {
            vm.prank(centralRegistry.protocolMessagingHub());
            cveLocker.recordEpochRewards(1e6);
        }

        vm.warp(unlockTime);

        skip(veCVE.RESTRICTION_DURATION() + 1);

        vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
        veCVE.bridgeLock(0, bridgeData, rewardsData, "", 0);
    }

    function test_bridgeLock_fail_whenNativeTokenIsNotEnoughToCoverFee(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            false,
            0
        );

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
        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            false,
            0
        );

        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);

        bridgeData.dstChainId = 42162;

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidWormholeChainId
                .selector
        );
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
        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            false,
            0
        );

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
