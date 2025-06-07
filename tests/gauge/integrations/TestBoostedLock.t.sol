// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import { IEToken } from "contracts/interfaces/IEToken.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { ETokenWithGauge } from "contracts/market/token/withGauge/ETokenWithGauge.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract User {}

contract TestBoostedLock is TestBaseMarketIsolated {
    address public owner;
    address[] public tokens;
    address[] public users;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();
        tokens = new address[](10);
        users = new address[](10);

        // prepare 200K USDC
        _prepareUSDC(user1, 200000e6);
        _prepareUSDC(user2, 200000e6);
        _prepareUSDC(liquidator, 200000e6);
        _prepareUSDC(address(rewardManager), 10000000e6);

        // prepare 1 BAL-RETH/WETH
        _prepareBALRETH(user1, 1 ether);
        _prepareBALRETH(user2, 1 ether);
        _prepareBALRETH(liquidator, 1 ether);

        owner = address(this);

        _prepareDAI(owner, 200000e18);

        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(new User());
            _prepareDAI(users[i], 200000e18);
        }
        for (uint256 i = 0; i < 10; i++) {
            tokens[i] = address(_deployEDAI());
        }

        for (uint256 i = 0; i < 10; i++) {
            // support market
            dai.approve(address(tokens[i]), 200000e18);
            marketManagerIsolated.listToken(tokens[i]);

            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(tokens[i]);

            for (uint256 j = 0; j < 10; j++) {
                address user = users[j];

                // approve
                vm.prank(user);
                dai.approve(address(tokens[i]), 200000e18);
            }

            // sort token addresses
            for (uint256 j = i; j > 0; j--) {
                if (tokens[j] < tokens[j - 1]) {
                    address temp = tokens[j];
                    tokens[j] = tokens[j - 1];
                    tokens[j - 1] = temp;
                }
            }
        }

        address[] memory tokensParam = new address[](1);
        tokensParam[0] = tokens[0];
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 100;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

        // start epoch

        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);
    }

    function testBoostedLockFromClaim() public {
        _skipEpochDuration(1);

        // set gauge weights
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = tokens[0];
        tokensParam[1] = tokens[1];
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100e18 * 2 weeks;
        poolWeights[1] = 200e18 * 2 weeks;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300e18 * 2 weeks);

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(100 ether);

        // user2 deposit 100 token1
        vm.prank(users[2]);
        IEToken(tokens[1]).mint(100 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0]) / 1e18,
            10000 - 1
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[2]) / 1e18,
            20000 - 1
        );

        // user1 deposit 400 token0
        vm.prank(users[1]);
        IEToken(tokens[0]).mint(400 ether);

        // user3 deposit 400 token1
        vm.prank(users[3]);
        IEToken(tokens[1]).mint(400 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0]) / 1e18,
            12000 - 1
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[1]) / 1e18,
            8000 - 1
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[2]) / 1e18,
            24000 - 1
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[3]) / 1e18,
            16000 - 1
        );

        vm.prank(address(messagingHub));
        rewardManager.recordEpochRewards(1e6 * _ONE);

        _skipRestrictionDuration();

        // user0, user3 claims
        RewardsData memory rewardData;
        vm.prank(users[0]);
        gaugeManager.claimAndLock(
            _makeTokenArray(tokens[0]),
            true, // isNewLock
            false, // continuousLock
            0, // lockIndex
            rewardData,
            "",
            0
        );
        vm.prank(users[3]);
        gaugeManager.claimAndLock(
            _makeTokenArray(tokens[1]),
            true, // isNewLock
            false, // continuousLock
            0, // lockIndex
            rewardData,
            "",
            0
        );
        assertEq(veCVE.balanceOf(users[0]) / 1e18, 1138825);
        assertEq(veCVE.balanceOf(users[3]) / 1e18, 9006607);
        assertApproxEqAbs(veCVE.getVotes(users[0]), 1095025e18, 1e18);
        assertApproxEqAbs(veCVE.getVotes(users[3]), 8660200e18, 1e18);

        vm.warp(block.timestamp + 1000);

        // user0, user3 claims
        vm.prank(users[0]);
        gaugeManager.claimAndLock(
            _makeTokenArray(tokens[0]),
            false, // isNewLock
            true, // continuousLock
            0, // lockIndex
            rewardData,
            "",
            0
        );
        vm.prank(users[3]);
        gaugeManager.claimAndLock(
            _makeTokenArray(tokens[1]),
            false, // isNewLock
            false, // continuousLock
            0, // lockIndex
            rewardData,
            "",
            0
        );

        assertEq(veCVE.balanceOf(users[0]) / 1e18, 1164825);
        assertEq(veCVE.balanceOf(users[3]) / 1e18, 9214607);
        assertEq(veCVE.getVotes(users[0]) / 1e18, 1397791);
        assertApproxEqAbs(veCVE.getVotes(users[3]), 8860200e18, 1e18);

        vm.warp(block.timestamp + 6 weeks);
        assertEq(veCVE.balanceOf(users[0]) / 1e18, 1164825);
        assertEq(veCVE.balanceOf(users[3]) / 1e18, 9214607);
        assertEq(veCVE.getVotes(users[0]) / 1e18, 1397791);
        assertApproxEqAbs(veCVE.getVotes(users[3]), 7796976e18, 1e18);
    }

    function testRevertClaimAndExtendLock() public {
        vm.warp(gaugeManager.gaugeStartTime() - 1);

        RewardsData memory rewardData;

        vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
        vm.prank(users[0]);
        gaugeManager.claimAndLock(
            _makeTokenArray(address(cve)),
            false, // isNewLock
            true, // continuousLock
            0, // lockIndex
            rewardData,
            "",
            0
        );

        vm.warp(gaugeManager.gaugeStartTime());
        vm.expectRevert(GaugeManager.GaugeManager__NoReward.selector);
        vm.prank(users[0]);
        gaugeManager.claimAndLock(
            _makeTokenArray(address(cve)),
            false, // isNewLock
            true, // continuousLock
            0, // lockIndex
            rewardData,
            "",
            0
        );
    }

    function testRevertClaimAndLock() public {
        vm.warp(gaugeManager.gaugeStartTime() - 1);

        RewardsData memory rewardData;

        vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
        vm.prank(users[0]);
        gaugeManager.claimAndLock(
            _makeTokenArray(address(cve)),
            true,
            true,
            0,
            rewardData,
            "",
            0
        );

        vm.warp(gaugeManager.gaugeStartTime());
        vm.expectRevert(GaugeManager.GaugeManager__NoReward.selector);
        vm.prank(users[0]);
        gaugeManager.claimAndLock(
            _makeTokenArray(address(cve)),
            true,
            true,
            0,
            rewardData,
            "",
            0
        );
    }

    // Deploy ETokenWithGauge
    function _deployEToken(
        address token
    ) internal override initMainVariables returns (EToken) {
        EToken eToken = EToken(
            address(
                new ETokenWithGauge(
                    ICentralRegistry(address(centralRegistry)),
                    token,
                    address(marketManagerIsolated),
                    _deployDynamicInterestRateModel(token)
                )
            )
        );

        interestRateModels[block.chainid][token].setLinkedEToken(
            address(eToken)
        );

        return eToken;
    }
}
