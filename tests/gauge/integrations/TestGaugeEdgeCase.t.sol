// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockToken } from "contracts/mocks/MockToken.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract User {}

contract TestGaugeEdgeCase is TestBaseMarket {
    address public owner;
    address[] public tokens;
    address[] public users;

    uint256 constant CHILD_GAUGE_COUNT = 5;
    address[CHILD_GAUGE_COUNT] public partnerRewardTokens;

    MockDataFeed public mockDaiFeed;

    function setUp() public override {
        super.setUp();
        tokens = new address[](10);
        users = new address[](10);

        // prepare 200K USDC
        _prepareUSDC(user1, 200000e6);
        _prepareUSDC(user2, 200000e6);
        _prepareUSDC(liquidator, 200000e6);

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
            tokens[i] = address(_deployDDAI());
        }

        for (uint256 i = 0; i < 10; i++) {
            // support market
            dai.approve(address(tokens[i]), 200000e18);
            marketManager.listToken(tokens[i]);

            // add MToken support on price router
            oracleRouter.addMTokenSupport(tokens[i]);

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

        // add partner gauges
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            partnerRewardTokens[i] = address(
                new MockToken("Reward Token", "RT", 18)
            );
            MockToken(partnerRewardTokens[i]).approve(
                address(gaugeManager),
                1000 ether
            );

            gaugeManager.addExtraRewardToken(
                address(partnerRewardTokens[i]),
                100
            );
        }

        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
    }

    function testCannotRedeemMoreThanDeposit() public {
        // user0 deposit 100 token0
        vm.prank(users[0]);
        vm.expectRevert();
        IMToken(tokens[0]).mint(100 ether);

        // user0 withdraw half
        vm.prank(users[0]);
        vm.expectRevert();
        IMToken(tokens[0]).redeem(101 ether);
    }

    function testCannotDepositWithdrawBeforeGaugeStart() public {
        // user0 deposit 100 token0
        vm.prank(users[0]);
        vm.expectRevert();
        IMToken(tokens[0]).mint(100 ether);

        // user1 deposit 100 token1
        vm.prank(users[1]);
        vm.expectRevert();
        IMToken(tokens[1]).mint(100 ether);

        // user0 withdraw half
        vm.prank(users[0]);
        vm.expectRevert();
        IMToken(tokens[0]).redeem(50 ether);
    }

    function testCannotStartWithoutDaoPermissions() public {
        // start epoch
        vm.prank(users[0]);
        vm.expectRevert(GaugeManager.GaugeManager__Unauthorized.selector);
            }

    function testCannotCalculateEpochWhenNotStarted() public {
        vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
        gaugeManager.epochOfTimestamp(block.timestamp);
    }

    function testCanDepositWithdrawBeforeGaugeStartTime() public {
        // start epoch
        
        // user0 deposit 100 token0
        vm.prank(users[0]);
        IMToken(tokens[0]).mint(100 ether);

        // user1 deposit 100 token1
        vm.prank(users[1]);
        IMToken(tokens[1]).mint(100 ether);

        // user0 withdraw half
        vm.prank(users[0]);
        IMToken(tokens[0]).redeem(50 ether);
    }

    function testCanDepositWithdrawAfterGaugeStartTime() public {
        // start epoch
        
        vm.warp(gaugeManager.startTime() + 10 seconds);
        vm.roll(block.number + 1000);

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IMToken(tokens[0]).mint(100 ether);

        // user1 deposit 100 token1
        vm.prank(users[1]);
        IMToken(tokens[1]).mint(100 ether);

        // user0 withdraw half
        vm.prank(users[0]);
        IMToken(tokens[0]).redeem(50 ether);
    }

    function testSetPartnerGaugesWithoutCVE() public {
        // start epoch
        
        // setup partner gauge without CVE
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                partnerRewardTokens[i],
                100 * 2 weeks
            );
            gaugeManager.addExtraRewards(
                tokens[1],
                1,
                partnerRewardTokens[i],
                200 * 2 weeks
            );
        }

        vm.warp(gaugeManager.startTime());
        _skipEpochDuration(1);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IMToken(tokens[0]).mint(100 ether);

        // user1 deposit 100 token1
        vm.prank(users[1]);
        IMToken(tokens[1]).mint(100 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            0
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[1], address(cve)),
            0
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                10000
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[1],
                    partnerRewardTokens[i]
                ),
                20000
            );
        }
    }

    function testClaimWhenCVERewardIsZero() public {
        // start epoch
        
        // setup partner gauge without CVE
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                partnerRewardTokens[i],
                100 * 2 weeks
            );
            gaugeManager.addExtraRewards(
                tokens[1],
                1,
                partnerRewardTokens[i],
                200 * 2 weeks
            );
        }

        vm.warp(gaugeManager.startTime());
        _skipEpochDuration(1);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IMToken(tokens[0]).mint(100 ether);

        // user1 deposit 100 token1
        vm.prank(users[1]);
        IMToken(tokens[1]).mint(100 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            0
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[1], address(cve)),
            0
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                10000
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[1],
                    partnerRewardTokens[i]
                ),
                20000
            );
        }

        vm.prank(users[0]);
        gaugeManager.claim(tokens);
    }
}
