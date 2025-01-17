// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import { IEToken } from "contracts/interfaces/IEToken.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { MockToken } from "contracts/mocks/MockToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract User {}

contract TestPartnerGaugePool is TestBaseMarket {
    address public owner;
    address[] public tokens;
    address[] public users;

    uint256 constant CHILD_GAUGE_COUNT = 5;
    address[CHILD_GAUGE_COUNT] public partnerRewardTokens;

    MockDataFeed public mockDaiFeed;

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
            marketManager.listToken(tokens[i]);

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

    function startGauge() internal {
        // start epoch

        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);
    }

    function testPartnerGaugesRewardsBeforeGaugeStart() public {
        vm.warp(gaugeManager.startTime() + 1);

        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
            gaugeManager.addExtraRewards(
                tokens[0],
                0,
                partnerRewardTokens[i],
                100 * 2 weeks
            );
            vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
            gaugeManager.addExtraRewards(
                tokens[1],
                0,
                partnerRewardTokens[i],
                200 * 2 weeks
            );
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

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(100 ether);

        // user2 deposit 100 token1
        vm.prank(users[2]);
        IEToken(tokens[1]).mint(100 ether);
    }

    function testRevertAddExtraRewardTokenInvalidAddress() public {
        startGauge();

        vm.expectRevert(GaugeManager.GaugeManager__InvalidAddress.selector);
        gaugeManager.addExtraRewardToken(address(0), 100);

        vm.expectRevert(GaugeManager.GaugeManager__InvalidAddress.selector);
        gaugeManager.addExtraRewardToken(address(partnerRewardTokens[0]), 100);
    }

    function testRevertRemoveExtraRewardToken() public {
        startGauge();

        vm.expectRevert(GaugeManager.GaugeManager__Unauthorized.selector);
        gaugeManager.removeExtraRewardToken(address(cve));
    }

    function testSuccessRemoveExtraReward() public {
        startGauge();

        // assertEq(gaugeManager.getRewardTokensLength(), CHILD_GAUGE_COUNT + 1);

        // gaugeManager.removeExtraRewardToken(address(partnerRewardTokens[0]));

        // assertEq(gaugeManager.getRewardTokensLength(), CHILD_GAUGE_COUNT);
    }

    function testSetMinDistributionAmountRevertInvalidRewardToken() public {
        startGauge();

        vm.expectRevert(
            GaugeManager.GaugeManager__InvalidRewardToken.selector
        );
        gaugeManager.setMinDistributionAmount(address(0), 400);
    }

    function testSetMinDistributionAmount() public {
        startGauge();

        assertEq(
            gaugeManager.rewardTokenToMinDistribution(
                address(partnerRewardTokens[0])
            ),
            100
        );

        gaugeManager.setMinDistributionAmount(
            address(partnerRewardTokens[0]),
            400
        );

        assertEq(
            gaugeManager.rewardTokenToMinDistribution(
                address(partnerRewardTokens[0])
            ),
            400
        );
    }

    function testRevertAddExtraRewardsInvalidEpoch() public {
        startGauge();

        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
            gaugeManager.addExtraRewards(
                tokens[0],
                0,
                partnerRewardTokens[i],
                300 * 2 weeks
            );
        }
    }

    function testRevertAddExtraRewardsInvalidRewardTokenAmount() public {
        startGauge();

        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            gaugeManager.setMinDistributionAmount(
                address(partnerRewardTokens[i]),
                300 * 2 weeks + 1
            );
            vm.expectRevert(GaugeManager.GaugeManager__InvalidAmount.selector);
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                partnerRewardTokens[i],
                300 * 2 weeks
            );
        }
    }

    function testRevertAddExtraRewardsUnauthorized() public {
        startGauge();

        vm.expectRevert(GaugeManager.GaugeManager__Unauthorized.selector);
        gaugeManager.addExtraRewards(
            tokens[0],
            0,
            address(cve),
            300 * 2 weeks
        );
    }

    function testRevertAddExtraRewardsInvalidRewardToken() public {
        startGauge();

        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            vm.expectRevert(
                GaugeManager.GaugeManager__InvalidRewardToken.selector
            );
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                address(this),
                300 * 2 weeks
            );
        }
    }

    function testUpdateRewardPerSec() public {
        startGauge();

        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                partnerRewardTokens[i],
                300 * 2 weeks
            );
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                partnerRewardTokens[i],
                200 * 2 weeks
            );
        }
    }

    function testPartnerGaugesRewardRatioOfDifferentPools() public {
        startGauge();

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

        _skipEpochDuration(1);

        // set gauge weights
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = tokens[0];
        tokensParam[1] = tokens[1];
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100 * 2 weeks;
        poolWeights[1] = 200 * 2 weeks;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(100 ether);

        // user2 deposit 100 token1
        vm.prank(users[2]);
        IEToken(tokens[1]).mint(100 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            9999
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[2], address(cve)),
            19999
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                9999
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[2],
                    partnerRewardTokens[i]
                ),
                19999
            );
        }

        // user1 deposit 400 token0
        vm.prank(users[1]);
        IEToken(tokens[0]).mint(400 ether);

        // user3 deposit 400 token1
        vm.prank(users[3]);
        IEToken(tokens[1]).mint(400 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            11999
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[1], address(cve)),
            8000
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[2], address(cve)),
            23999
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[3], address(cve)),
            16000
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                11999
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[1],
                    partnerRewardTokens[i]
                ),
                8000
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[2],
                    partnerRewardTokens[i]
                ),
                23999
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[3],
                    partnerRewardTokens[i]
                ),
                16000
            );
        }

        // user0, user3 claims
        vm.prank(users[0]);
        gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
        vm.prank(users[3]);
        gaugeManager.claim(_makeTokenArray(tokens[1]), users[3]);

        assertEq(cve.balanceOf(users[0]), 11999);
        assertEq(cve.balanceOf(users[3]), 16000);
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                MockToken(partnerRewardTokens[i]).balanceOf(users[0]),
                11999
            );
            assertEq(
                MockToken(partnerRewardTokens[i]).balanceOf(users[3]),
                16000
            );
        }

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            2000
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[1], address(cve)),
            16000
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[2], address(cve)),
            27999
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[3], address(cve)),
            16000
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                2000
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[1],
                    partnerRewardTokens[i]
                ),
                16000
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[2],
                    partnerRewardTokens[i]
                ),
                27999
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[3],
                    partnerRewardTokens[i]
                ),
                16000
            );
        }

        // user0 withdraw half
        vm.prank(users[0]);
        IEToken(tokens[0]).redeem(50 ether, address(this));

        // user2 deposit 2x
        vm.prank(users[2]);
        IEToken(tokens[1]).mint(100 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            3112
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[1], address(cve)),
            24889
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[2], address(cve)),
            34666
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[3], address(cve)),
            29334
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                3112
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[1],
                    partnerRewardTokens[i]
                ),
                24889
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[2],
                    partnerRewardTokens[i]
                ),
                34666
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[3],
                    partnerRewardTokens[i]
                ),
                29334
            );
        }

        // user0, user1, user2, user3 claims
        vm.prank(users[0]);

        gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
        vm.prank(users[1]);
        gaugeManager.claim(_makeTokenArray(tokens[0]), users[1]);
        vm.prank(users[2]);
        gaugeManager.claim(_makeTokenArray(tokens[1]), users[2]);
        vm.prank(users[3]);
        gaugeManager.claim(_makeTokenArray(tokens[1]), users[3]);

        assertEq(cve.balanceOf(users[0]), 15111);
        assertEq(cve.balanceOf(users[1]), 24889);
        assertEq(cve.balanceOf(users[2]), 34666);
        assertEq(cve.balanceOf(users[3]), 45334);
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                MockToken(partnerRewardTokens[i]).balanceOf(users[0]),
                15111
            );
            assertEq(
                MockToken(partnerRewardTokens[i]).balanceOf(users[1]),
                24889
            );
            assertEq(
                MockToken(partnerRewardTokens[i]).balanceOf(users[2]),
                34666
            );
            assertEq(
                MockToken(partnerRewardTokens[i]).balanceOf(users[3]),
                45334
            );
        }

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            1111
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[1], address(cve)),
            8889
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[2], address(cve)),
            6667
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[3], address(cve)),
            13333
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                1111
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[1],
                    partnerRewardTokens[i]
                ),
                8889
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[2],
                    partnerRewardTokens[i]
                ),
                6667
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[3],
                    partnerRewardTokens[i]
                ),
                13333
            );
        }
    }

    function testPartnerGaugesRewardCalculationWithDifferentEpoch() public {
        startGauge();

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

        _skipEpochDuration(1);

        // set gauge weights
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = tokens[0];
        tokensParam[1] = tokens[1];
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100 * 2 weeks;
        poolWeights[1] = 200 * 2 weeks;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(100 ether);

        // user1 deposit 100 token1
        vm.prank(users[1]);
        IEToken(tokens[1]).mint(100 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            9999
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[1], address(cve)),
            19999
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                9999
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[1],
                    partnerRewardTokens[i]
                ),
                19999
            );
        }

        // set next epoch reward per second
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            gaugeManager.addExtraRewards(
                tokens[0],
                2,
                partnerRewardTokens[i],
                200 * 2 weeks - 1
            );
            gaugeManager.addExtraRewards(
                tokens[1],
                2,
                partnerRewardTokens[i],
                200 * 2 weeks - 1
            );
        }

        _skipEpochDuration(1);

        // set gauge weights
        tokensParam[0] = tokens[0];
        tokensParam[1] = tokens[1];
        poolWeights[0] = 200 * 2 weeks;
        poolWeights[1] = 200 * 2 weeks;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(2, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 400 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        assertEq(
            gaugeManager.pendingRewards(tokens[0], users[0], address(cve)),
            2 weeks * 100 + 100 * 200 - 1
        );
        assertEq(
            gaugeManager.pendingRewards(tokens[1], users[1], address(cve)),
            2 weeks * 200 + 100 * 200 - 1
        );
        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                2 weeks * 100 + 100 * 200 - 101
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[1],
                    partnerRewardTokens[i]
                ),
                2 weeks * 200 + 100 * 200 - 101
            );
        }

        // user0, user1 claim rewards
        vm.prank(users[0]);
        gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
        vm.prank(users[1]);
        gaugeManager.claim(_makeTokenArray(tokens[1]), users[1]);

        assertEq(cve.balanceOf(users[0]), 2 weeks * 100 + 100 * 200 - 1);
        assertEq(cve.balanceOf(users[1]), 2 weeks * 200 + 100 * 200 - 1);
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
                MockToken(partnerRewardTokens[i]).balanceOf(users[0]),
                2 weeks * 100 + 100 * 200 - 101
            );
            assertEq(
                MockToken(partnerRewardTokens[i]).balanceOf(users[1]),
                2 weeks * 200 + 100 * 200 - 101
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[0],
                    users[0],
                    partnerRewardTokens[i]
                ),
                0
            );
            assertEq(
                gaugeManager.pendingRewards(
                    tokens[1],
                    users[1],
                    partnerRewardTokens[i]
                ),
                0
            );
        }
    }

    function testRewardsDistributionAfterRemoveExtraRewardToken() public {
        startGauge();

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

        _skipEpochDuration(1);

        // set gauge weights
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = tokens[0];
        tokensParam[1] = tokens[1];
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100 * 2 weeks;
        poolWeights[1] = 200 * 2 weeks;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(100 ether);

        // user2 deposit 100 token1
        vm.prank(users[2]);
        IEToken(tokens[1]).mint(100 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[0]
            ),
            9999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[0]
            ),
            19999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[1]
            ),
            9999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[1]
            ),
            19999
        );

        // assertEq(gaugeManager.getRewardTokensLength(), CHILD_GAUGE_COUNT + 1);

        gaugeManager.removeExtraRewardToken(address(partnerRewardTokens[0]));

        // assertEq(gaugeManager.getRewardTokensLength(), CHILD_GAUGE_COUNT);

        vm.expectRevert(
            GaugeManager.GaugeManager__InvalidRewardToken.selector
        );
        gaugeManager.pendingRewards(
            tokens[0],
            users[0],
            partnerRewardTokens[0]
        );
        vm.expectRevert(
            GaugeManager.GaugeManager__InvalidRewardToken.selector
        );
        gaugeManager.pendingRewards(
            tokens[1],
            users[2],
            partnerRewardTokens[0]
        );

        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[1]
            ),
            9999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[1]
            ),
            19999
        );

        vm.warp(block.timestamp + 100);

        vm.expectRevert(
            GaugeManager.GaugeManager__InvalidRewardToken.selector
        );
        gaugeManager.pendingRewards(
            tokens[0],
            users[0],
            partnerRewardTokens[0]
        );
        vm.expectRevert(
            GaugeManager.GaugeManager__InvalidRewardToken.selector
        );
        gaugeManager.pendingRewards(
            tokens[1],
            users[2],
            partnerRewardTokens[0]
        );

        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[1]
            ),
            19999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[1]
            ),
            39999
        );
    }

    function testReAddExtraRewardToken() public {
        startGauge();

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

        _skipEpochDuration(1);

        // set gauge weights
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = tokens[0];
        tokensParam[1] = tokens[1];
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100 * 2 weeks;
        poolWeights[1] = 200 * 2 weeks;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // user0 deposit 100 token0
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(100 ether);

        // user2 deposit 100 token1
        vm.prank(users[2]);
        IEToken(tokens[1]).mint(100 ether);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[0]
            ),
            9999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[0]
            ),
            19999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[1]
            ),
            9999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[1]
            ),
            19999
        );

        // assertEq(gaugeManager.getRewardTokensLength(), CHILD_GAUGE_COUNT + 1);

        gaugeManager.removeExtraRewardToken(address(partnerRewardTokens[0]));

        // assertEq(gaugeManager.getRewardTokensLength(), CHILD_GAUGE_COUNT);

        vm.expectRevert(
            GaugeManager.GaugeManager__InvalidRewardToken.selector
        );
        gaugeManager.pendingRewards(
            tokens[0],
            users[0],
            partnerRewardTokens[0]
        );
        vm.expectRevert(
            GaugeManager.GaugeManager__InvalidRewardToken.selector
        );
        gaugeManager.pendingRewards(
            tokens[1],
            users[2],
            partnerRewardTokens[0]
        );

        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[1]
            ),
            9999
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[1]
            ),
            19999
        );

        gaugeManager.addExtraRewardToken(address(partnerRewardTokens[0]), 100);

        for (uint256 i = 0; i < CHILD_GAUGE_COUNT; i++) {
            gaugeManager.addExtraRewards(
                tokens[0],
                2,
                partnerRewardTokens[i],
                100 * 2 weeks - 1
            );
            gaugeManager.addExtraRewards(
                tokens[1],
                2,
                partnerRewardTokens[i],
                200 * 2 weeks - 1
            );
        }

        _skipEpochDuration(1);

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(2, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[0]
            ),
            100 * (2 weeks + 100) - 101
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[0]
            ),
            200 * (2 weeks + 100) - 101
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[1]
            ),
            100 * (2 weeks + 100) - 101
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[1]
            ),
            200 * (2 weeks + 100) - 101
        );

        vm.warp(block.timestamp + 100);

        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[0]
            ),
            100 * (2 weeks + 200) - 201
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[0]
            ),
            200 * (2 weeks + 200) - 201
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[0],
                users[0],
                partnerRewardTokens[1]
            ),
            100 * (2 weeks + 200) - 201
        );
        assertEq(
            gaugeManager.pendingRewards(
                tokens[1],
                users[2],
                partnerRewardTokens[1]
            ),
            200 * (2 weeks + 200) - 201
        );
    }
}
