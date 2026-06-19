// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract MessagingHubHarness is MessagingHub {
    constructor(ICentralRegistry cr) MessagingHub(cr) {}

    function exposedExecuteCrosschainEpoch(
        uint256[] memory chainIds,
        uint256[] memory chainPoints,
        uint256 epochToDeliver,
        uint256 numChains,
        uint256 totalPoints,
        uint256 gasLimit
    ) external {
        _executeCrosschainEpoch(
            chainIds,
            chainPoints,
            epochToDeliver,
            numChains,
            totalPoints,
            gasLimit
        );
    }
}

contract MessagingHubFeeDistributionRoundingTest is TestBaseMarketIsolated {
    MessagingHubHarness internal messagingHubHarness;

    function setUp() public override {
        _fork(23263997);
        _deployBaseContracts();
        _skipRestrictionDuration();

        messagingHubHarness = new MessagingHubHarness(
            ICentralRegistry(address(centralRegistry))
        );
        messagingHub = MessagingHub(payable(address(messagingHubHarness)));
        centralRegistry.setMessagingHub(address(messagingHubHarness));
    }

    function test_executeCrosschainEpoch_fundsLocalRewardManagerForRoundedClaim()
        public
    {
        uint256 feeAmount = 1;
        uint256 lockAmount = 1e18;
        ClaimAction memory action;

        _prepareCVE(user1, lockAmount);

        vm.startPrank(user1);
        cve.approve(address(veCVE), lockAmount);
        veCVE.createLock(lockAmount, true, action, bytes(""), 0);
        vm.stopPrank();

        assertEq(veCVE.chainPoints(), 2e18, "continuous lock points");

        _prepareUSDC(address(messagingHubHarness), feeAmount);

        uint256[] memory chainIds = new uint256[](0);
        uint256[] memory chainPoints = new uint256[](0);
        uint256 epochToDeliver = rewardManager.nextEpochToDeliver();

        messagingHubHarness.exposedExecuteCrosschainEpoch(
            chainIds,
            chainPoints,
            epochToDeliver,
            0,
            0,
            0
        );

        assertEq(
            rewardManager.epochRewardsPerPoint(epochToDeliver),
            (feeAmount * 1e36) / veCVE.chainPoints(),
            "epoch rewards per point"
        );
        assertEq(
            usdc.balanceOf(address(rewardManager)),
            feeAmount,
            "reward manager must receive the claimable local reward"
        );
        assertEq(
            usdc.balanceOf(address(messagingHubHarness)),
            0,
            "messaging hub should not retain claimable local rewards"
        );

        vm.prank(user1);
        rewardManager.claimRewards(action, bytes(""), 0);

        assertEq(usdc.balanceOf(user1), feeAmount, "claim paid");
    }
}
