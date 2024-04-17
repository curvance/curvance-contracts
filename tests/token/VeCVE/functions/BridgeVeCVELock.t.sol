// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.17;

// import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
// import { VeCVE } from "contracts/token/VeCVE.sol";
// import { ITokenBridge } from "contracts/interfaces/external/wormhole/ITokenBridge.sol";

// contract BridgeVeCVELockTest is TestBaseVeCVE {
//     ITokenBridge public tokenBridge = ITokenBridge(_TOKEN_BRIDGE);

//     function setUp() public override {
//         super.setUp();

//         centralRegistry.addChainSupport(
//             address(this),
//             address(protocolMessagingHub),
//             address(cve),
//             _USDC_ADDRESS,
//             42161,
//             1,
//             1,
//             23
//         );

//         deal(_USDC_ADDRESS, address(cveLocker), 10000e6);
//         deal(address(cve), address(this), 100e18);
//         cve.approve(address(veCVE), 100e18);

//         vm.prank(centralRegistry.feeAccumulator());
//         cveLocker.recordEpochRewards(1e6);

//         skip(veCVE.RESTRICTION_DURATION() + 1);

//         veCVE.createLock(30e18, false, rewardsData, "", 0);
//         veCVE.createLock(30e18, true, rewardsData, "", 0);
//     }

//     function test_bridgeVeCVELock_fail_whenVeCVEIsShutdown(
//         bool shouldLock,
//         bool isFreshLock,
//         bool isFreshLockContinuous
//     ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
//         veCVE.shutdown();

//         vm.expectRevert(VeCVE.VeCVE__VeCVEShutdown.selector);
//         veCVE.bridgeVeCVELock(0, 42161, true, rewardsData, "", 0, 0);
//     }

//     function test_bridgeVeCVELock_fail_whenLockIndexExceeds(
//         bool shouldLock,
//         bool isFreshLock,
//         bool isFreshLockContinuous
//     ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
//         vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
//         veCVE.bridgeVeCVELock(2, 42161, true, rewardsData, "", 0, 0);
//     }

//     function test_bridgeVeCVELock_fail_whenLockIsExpired(
//         bool shouldLock,
//         bool isFreshLock,
//         bool isFreshLockContinuous
//     ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
//         (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);

//         for (
//             uint256 i = 0;
//             i <= (unlockTime - block.timestamp) / veCVE.EPOCH_DURATION();
//             i++
//         ) {
//             vm.prank(centralRegistry.feeAccumulator());
//             cveLocker.recordEpochRewards(1e6);
//         }

//         vm.warp(unlockTime);

//         skip(veCVE.RESTRICTION_DURATION() + 1);

//         vm.expectRevert(VeCVE.VeCVE__InvalidLock.selector);
//         veCVE.bridgeVeCVELock(0, 42161, true, rewardsData, "", 0, 0);
//     }

//     function test_bridgeVeCVELock_fail_whenNativeTokenIsNotEnoughToCoverFee(
//         bool shouldLock,
//         bool isFreshLock,
//         bool isFreshLockContinuous
//     ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
//         uint256 messageFee = protocolMessagingHub.quoteWormholeFee(
//             42161,
//             false,
//             0
//         );

//         vm.expectRevert();
//         veCVE.bridgeVeCVELock{ value: messageFee - 1 }(
//             1,
//             42161,
//             true,
//             rewardsData,
//             "",
//             0,
//             0
//         );
//     }

//     function test_bridgeVeCVELock_success(
//         bool shouldLock,
//         bool isFreshLock,
//         bool isFreshLockContinuous
//     ) public setRewardsData(shouldLock, isFreshLock, isFreshLockContinuous) {
//         uint256 messageFee = protocolMessagingHub.quoteWormholeFee(
//             42161,
//             false,
//             0
//         );

//         centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);

//         uint256 veCVEBalance = veCVE.balanceOf(address(this));
//         uint256 cveBalance = cve.balanceOf(address(this));
//         uint256 cveTotalSupply = cve.totalSupply();

//         veCVE.bridgeVeCVELock{ value: messageFee }(
//             0,
//             42161,
//             true,
//             rewardsData,
//             "",
//             0,
//             0
//         );

//         assertEq(veCVE.balanceOf(address(this)), 30e18);
//         assertEq(cve.balanceOf(address(this)), cveBalance);
//         assertEq(cve.totalSupply(), cveTotalSupply - veCVEBalance + 30e18);

//         veCVE.bridgeVeCVELock{ value: messageFee }(
//             0,
//             42161,
//             true,
//             rewardsData,
//             "",
//             0,
//             0
//         );
//     }
// }
