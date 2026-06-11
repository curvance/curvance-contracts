// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestVeCVERewardRegressions is TestBaseMarketIsolated {
    function setUp() public override {
        _fork(23263997);
        _deployBaseContracts();
        _skipRestrictionDuration();
    }

    function test_createLockFor_claimsRecipientRewardsBeforeIncreasingPoints()
        public
    {
        uint256 initialLockAmount = 100e18;
        uint256 newLockAmount = 50e18;
        ClaimAction memory action;

        _prepareCVE(user1, initialLockAmount);
        vm.startPrank(user1);
        cve.approve(address(veCVE), initialLockAmount);
        veCVE.createLock(initialLockAmount, false, action, bytes(""), 0);
        vm.stopPrank();

        deal(_USDC_ADDRESS, address(rewardManager), 1_000_000);
        vm.prank(address(messagingHub));
        rewardManager.recordEpochRewards(1e18);
        _skipEpochDuration(1);

        uint256 expectedRewards = rewardManager.hypotheticalRewardsClaim(user1);
        assertEq(expectedRewards, 100);
        assertEq(rewardManager.epochsToClaim(user1), 1);

        deal(address(cve), address(gaugeManager), newLockAmount);
        vm.startPrank(address(gaugeManager));
        cve.approve(address(veCVE), newLockAmount);
        veCVE.createLockFor(user1, newLockAmount, false, action, bytes(""), 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), expectedRewards);
        assertEq(rewardManager.epochsToClaim(user1), 0);
        assertEq(
            rewardManager.userNextClaimIndex(user1),
            rewardManager.nextEpochToDeliver()
        );
        assertEq(veCVE.userPoints(user1), initialLockAmount + newLockAmount);
    }

    function test_compoundRewardsIntoLock_freshLockUsesRecipient() public {
        uint256 amount = 5e18;

        deal(address(cve), address(rewardManager), amount);
        vm.prank(address(rewardManager));
        cve.approve(address(veCVE), amount);

        vm.prank(address(rewardManager));
        veCVE.compoundRewardsIntoLock(user1, amount, 0, true, false);

        (uint256[] memory userLockAmounts,) = veCVE.queryUserLocks(user1);
        (uint256[] memory rewardManagerLockAmounts,) = veCVE.queryUserLocks(
            address(rewardManager)
        );

        assertEq(userLockAmounts.length, 1);
        assertEq(userLockAmounts[0], amount);
        assertEq(rewardManagerLockAmounts.length, 0);
        assertEq(veCVE.balanceOf(user1), amount);
        assertEq(veCVE.balanceOf(address(rewardManager)), 0);
    }
}
