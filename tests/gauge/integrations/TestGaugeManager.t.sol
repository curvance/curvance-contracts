// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.15;

// import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
// import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
// import { EToken } from "contracts/market/token/EToken.sol";
// import { ETokenWithGauge } from "contracts/market/token/withGauge/ETokenWithGauge.sol";
// import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

// contract User {}

// contract TestGaugeManager is TestBaseMarketIsolated {
//     address public owner;
//     address[] public tokens;
//     address[] public users;

//     MockDataFeed public mockDaiFeed;

//     function setUp() public override {
//         super.setUp();
//         tokens = new address[](10);
//         users = new address[](10);

//         // prepare 200K USDC
//         _prepareUSDC(user1, 200000e6);
//         _prepareUSDC(user2, 200000e6);
//         _prepareUSDC(liquidator, 200000e6);

//         // prepare 1 BAL-RETH/WETH
//         _prepareBALRETH(user1, 1 ether);
//         _prepareBALRETH(user2, 1 ether);
//         _prepareBALRETH(liquidator, 1 ether);

//         owner = address(this);

//         _prepareDAI(owner, 200000e18);

//         for (uint256 i = 0; i < 10; i++) {
//             users[i] = address(new User());
//             _prepareDAI(users[i], 200000e18);
//         }
//         for (uint256 i = 0; i < 10; i++) {
//             tokens[i] = address(_deployEDAI());
//         }

//         for (uint256 i = 0; i < 10; i++) {
//             // support market
//             dai.approve(address(tokens[i]), 200000e18);
//             marketManagerIsolated.listToken(tokens[i]);

//             // add MToken support on oracle manager
//             oracleManager.addMTokenSupport(tokens[i]);

//             for (uint256 j = 0; j < 10; j++) {
//                 address user = users[j];

//                 // approve
//                 vm.prank(user);
//                 dai.approve(address(tokens[i]), 200000e18);
//             }

//             // sort token addresses
//             for (uint256 j = i; j > 0; j--) {
//                 if (tokens[j] < tokens[j - 1]) {
//                     address temp = tokens[j];
//                     tokens[j] = tokens[j - 1];
//                     tokens[j - 1] = temp;
//                 }
//             }
//         }

//         mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
//         chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
//     }

//     function testRevertLockStartTimeBeforeGenesisEpoch() public {
//         uint256 genesisEpoch = centralRegistry.genesisEpoch();
//         vm.warp(genesisEpoch - 1000);

//         vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
//         gaugeManager.lockInStartTime();
//     }

//     function testStartTimeShouldBeAfterLock() public {
//         uint256 genesisEpoch = centralRegistry.genesisEpoch();
//         uint256 epochDuration = gaugeManager.epochDuration();
//         vm.warp(genesisEpoch + 1000);

//         uint256 gaugeStartTimeBefore = gaugeManager.gaugeStartTime();
//         assertEq(
//             gaugeStartTimeBefore,
//             genesisEpoch +
//                 (((block.timestamp - genesisEpoch) / epochDuration) *
//                     epochDuration)
//         );

//         gaugeManager.lockInStartTime();
//         uint256 gaugeStartTimeAfter = gaugeManager.gaugeStartTime();
//         assertEq(gaugeStartTimeBefore, gaugeStartTimeAfter);
//     }

//     function testRevertSetEmissionRatesUnauthorized() public {
//         vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         // set gauge settings of next epoch
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100;
//         poolWeights[1] = 200;

//         vm.expectRevert(GaugeManager.GaugeManager__Unauthorized.selector);
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//     }

//     function testRevertSetEmissionRatesInvalidEpoch() public {
//         vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         // set gauge settings of next epoch
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100;
//         poolWeights[1] = 200;

//         vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(2, tokensParam, poolWeights);
//     }

//     function testRevertSetEmissionRatesInvalidLength() public {
//         vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         // set gauge settings of next epoch
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](1);
//         poolWeights[0] = 100;

//         vm.prank(address(messagingHub));

//         vm.expectRevert(GaugeManager.GaugeManager__InvalidLength.selector);
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);
//     }

//     function testRevertSetEmissionRatesInvalidToken() public {
//         vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         // set gauge settings of next epoch
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[1];
//         tokensParam[1] = tokens[0];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100;
//         poolWeights[1] = 200;

//         vm.prank(address(messagingHub));

//         vm.expectRevert(GaugeManager.GaugeManager__InvalidToken.selector);
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);
//     }

//     function testIsGaugeEnabled() public {
//         vm.warp(gaugeManager.gaugeStartTime());
//         _skipEpochDuration(1);

//         vm.roll(block.number + 1000);

//         // set gauge settings of next epoch
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100;
//         poolWeights[1] = 200;

//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);

//         assertEq(gaugeManager.isGaugeEnabled(1, tokens[0]), true);
//         assertEq(gaugeManager.isGaugeEnabled(1, tokens[2]), false);
//     }

//     function testManageEmissionRatesOfEachEpoch() public {
//         vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         assertEq(gaugeManager.currentEpoch(), 0);
//         assertEq(gaugeManager.epochOfTimestamp(block.timestamp + 3 weeks), 1);
//         assertEq(gaugeManager.epochStartTime(1), block.timestamp + 2 weeks);
//         assertEq(gaugeManager.epochEndTime(1), block.timestamp + 4 weeks);

//         // set gauge settings of current epoch
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100;
//         poolWeights[1] = 200;

//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

//         (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
//             0,
//             tokens[0]
//         );
//         assertEq(totalWeights, 300);
//         assertEq(poolWeight, 100);
//         (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, tokens[1]);
//         assertEq(totalWeights, 300);
//         assertEq(poolWeight, 200);
//     }

//     function testSecondEmissionRatesSetOfEachEpoch() public {
//         vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         assertEq(gaugeManager.currentEpoch(), 0);
//         assertEq(gaugeManager.epochOfTimestamp(block.timestamp + 3 weeks), 1);
//         assertEq(gaugeManager.epochStartTime(1), block.timestamp + 2 weeks);
//         assertEq(gaugeManager.epochEndTime(1), block.timestamp + 4 weeks);

//         // set gauge settings of current epoch
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100;
//         poolWeights[1] = 200;

//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

//         (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
//             0,
//             tokens[0]
//         );
//         assertEq(totalWeights, 300);
//         assertEq(poolWeight, 100);
//         (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, tokens[1]);
//         assertEq(totalWeights, 300);
//         assertEq(poolWeight, 200);

//         poolWeights[0] = 200;
//         poolWeights[1] = 100;

//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

//         (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, tokens[0]);
//         assertEq(totalWeights, 600);
//         assertEq(poolWeight, 300);
//         (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, tokens[1]);
//         assertEq(totalWeights, 600);
//         assertEq(poolWeight, 300);
//     }

//     function testCanOnlyUpdateEmissionRatesOfNextEpoch() public {
//         vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         assertEq(gaugeManager.currentEpoch(), 0);
//         assertEq(gaugeManager.epochOfTimestamp(block.timestamp + 3 weeks), 1);
//         assertEq(gaugeManager.epochStartTime(1), block.timestamp + 2 weeks);
//         assertEq(gaugeManager.epochEndTime(1), block.timestamp + 4 weeks);

//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100;
//         poolWeights[1] = 200;

//         // check invalid epoch
//         vm.startPrank(address(messagingHub));

//         vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//         vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
//         gaugeManager.setEmissionRates(2, tokensParam, poolWeights);

//         // can update emission rate of current epoch
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

//         vm.stopPrank();

//         (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
//             0,
//             tokens[0]
//         );
//         assertEq(totalWeights, 300);
//         assertEq(poolWeight, 100);
//         (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, tokens[1]);
//         assertEq(totalWeights, 300);
//         assertEq(poolWeight, 200);
//     }

//     function testRevertDepositInvalidToken() public {
//         vm.expectRevert(GaugeManager.GaugeManager__InvalidToken.selector);
//         gaugeManager.deposit(tokens[0], address(this), 100 ether);

//         vm.expectRevert(GaugeManager.GaugeManager__InvalidToken.selector);
//         gaugeManager.withdraw(tokens[0], address(this), 100 ether);
//     }

//     function testRevertClaim() public {
//         vm.warp(gaugeManager.gaugeStartTime() - 1);

//         vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
//         vm.prank(users[0]);
//         gaugeManager.claim(_makeTokenArray(address(cve)), users[0]);
//     }

//     function testEmptyClaim() public {
//         vm.warp(gaugeManager.gaugeStartTime());

//         vm.prank(users[0]);
//         gaugeManager.claim(new address[](0), users[0]);
//     }

//     function testRewardRatioOfDifferentPools() public {
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user2 deposit 100 token1
//         vm.prank(users[2]);
//         IEToken(tokens[1]).mint(100 ether);

//         vm.warp(gaugeManager.gaugeStartTime());
//         _skipEpochDuration(1);

//         vm.roll(block.number + 1000);

//         // set gauge weights
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100 * 2 weeks;
//         poolWeights[1] = 200 * 2 weeks;
//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//         vm.prank(address(messagingHub));
//         cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

//         mockDaiFeed.setMockUpdatedAt(block.timestamp);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 9999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 19999);

//         // user1 deposit 400 token0
//         vm.prank(users[1]);
//         IEToken(tokens[0]).mint(400 ether);

//         // user3 deposit 400 token1
//         vm.prank(users[3]);
//         IEToken(tokens[1]).mint(400 ether);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 11999);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 8000);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 23999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 16000);

//         // user0, user3 claims

//         vm.prank(users[0]);
//         gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
//         vm.prank(users[3]);
//         gaugeManager.claim(_makeTokenArray(tokens[1]), users[3]);

//         assertEq(cve.balanceOf(users[0]), 11999);
//         assertEq(cve.balanceOf(users[3]), 16000);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 2000);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 16000);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 27999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 16000);

//         // user0 withdraw half
//         vm.prank(users[0]);
//         IEToken(tokens[0]).redeem(50 ether, address(this));

//         // user2 deposit 2x
//         vm.prank(users[2]);
//         IEToken(tokens[1]).mint(100 ether);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 3112);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 24889);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 34666);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 29334);

//         // user0, user1, user2, user3 claims

//         vm.prank(users[0]);
//         gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
//         vm.prank(users[1]);
//         gaugeManager.claim(_makeTokenArray(tokens[0]), users[1]);
//         vm.prank(users[2]);
//         gaugeManager.claim(_makeTokenArray(tokens[1]), users[2]);
//         vm.prank(users[3]);
//         gaugeManager.claim(_makeTokenArray(tokens[1]), users[3]);

//         assertEq(cve.balanceOf(users[0]), 15111);
//         assertEq(cve.balanceOf(users[1]), 24889);
//         assertEq(cve.balanceOf(users[2]), 34666);
//         assertEq(cve.balanceOf(users[3]), 45334);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 1111);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 8889);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 6667);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 13333);
//     }

//     function testRewardCalculationWithDifferentEpoch() public {
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user1 deposit 100 token1
//         vm.prank(users[1]);
//         IEToken(tokens[1]).mint(100 ether);

//         vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         vm.startPrank(address(messagingHub));

//         // set gauge weights
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100 * 2 weeks;
//         poolWeights[1] = 200 * 2 weeks;

//         _skipEpochDuration(1);

//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//         cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

//         mockDaiFeed.setMockUpdatedAt(block.timestamp);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 9999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[1]), 19999);

//         // set gauge weights
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         poolWeights[0] = 200 * 2 weeks;
//         poolWeights[1] = 200 * 2 weeks;

//         _skipEpochDuration(1);

//         gaugeManager.setEmissionRates(2, tokensParam, poolWeights);
//         cve.mintGaugeEmissions(address(gaugeManager), 400 * 2 weeks);

//         vm.stopPrank();

//         // check pending rewards after 2 weeks
//         mockDaiFeed.setMockUpdatedAt(block.timestamp);
//         assertEq(
//             gaugeManager.pendingRewards(tokens[0], users[0]),
//             2 weeks * 100 + 100 * 200 - 1
//         );
//         assertEq(
//             gaugeManager.pendingRewards(tokens[1], users[1]),
//             2 weeks * 200 + 100 * 200 - 1
//         );

//         // user0, user1 claim rewards
//         vm.prank(users[0]);
//         gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
//         vm.prank(users[1]);
//         gaugeManager.claim(_makeTokenArray(tokens[1]), users[1]);

//         assertEq(cve.balanceOf(users[0]), 2 weeks * 100 + 100 * 200 - 1);
//         assertEq(cve.balanceOf(users[1]), 2 weeks * 200 + 100 * 200 - 1);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 0);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[1]), 0);
//     }

//     function testMassUpdatePoolDoesNotMessUpTheRewardCalculation() public {
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user2 deposit 100 token1
//         vm.prank(users[2]);
//         IEToken(tokens[1]).mint(100 ether);

//         vm.warp(gaugeManager.gaugeStartTime());
//         _skipEpochDuration(1);

//         vm.roll(block.number + 1000);

//         // set gauge weights
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100 * 2 weeks;
//         poolWeights[1] = 200 * 2 weeks;
//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//         vm.prank(address(messagingHub));
//         cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

//         mockDaiFeed.setMockUpdatedAt(block.timestamp);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         gaugeManager.massUpdatePools(tokensParam);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 9999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 19999);
//     }

//     function testPendingRewardsReturnsAllRewards() public {
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user2 deposit 100 token1
//         vm.prank(users[2]);
//         IEToken(tokens[1]).mint(100 ether);

//         vm.warp(gaugeManager.gaugeStartTime());
//         _skipEpochDuration(1);

//         vm.roll(block.number + 1000);

//         // set gauge weights
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100 * 2 weeks;
//         poolWeights[1] = 200 * 2 weeks;
//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//         vm.prank(address(messagingHub));
//         cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

//         mockDaiFeed.setMockUpdatedAt(block.timestamp);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         gaugeManager.massUpdatePools(tokensParam);
//         uint256[] memory rewards = gaugeManager.pendingRewards(
//             _makeTokenArray(tokens[0]),
//             users[0]
//         );
//         assertEq(rewards[0], 9999);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 9999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 19999);
//     }

//     function testUpdatePoolDoesNotMessUpTheRewardCalculation() public {
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user2 deposit 100 token1
//         vm.prank(users[2]);
//         IEToken(tokens[1]).mint(100 ether);

//         vm.warp(gaugeManager.gaugeStartTime());
//         _skipEpochDuration(1);

//         vm.roll(block.number + 1000);

//         // set gauge weights
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100 * 2 weeks;
//         poolWeights[1] = 200 * 2 weeks;
//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//         vm.prank(address(messagingHub));
//         cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

//         mockDaiFeed.setMockUpdatedAt(block.timestamp);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 9999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 19999);

//         // user1 deposit 400 token0
//         vm.prank(users[1]);
//         IEToken(tokens[0]).mint(400 ether);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // user3 deposit 400 token1
//         vm.prank(users[3]);
//         IEToken(tokens[1]).mint(400 ether);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 11999);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 8000);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 23999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 16000);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // user0, user3 claims
//         vm.prank(users[0]);
//         gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
//         vm.prank(users[3]);
//         gaugeManager.claim(_makeTokenArray(tokens[1]), users[3]);

//         assertEq(cve.balanceOf(users[0]), 11999);
//         assertEq(cve.balanceOf(users[3]), 16000);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 2000);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 16000);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 27999);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 16000);

//         // user0 withdraw half
//         vm.prank(users[0]);
//         IEToken(tokens[0]).redeem(50 ether, address(this));

//         // user2 deposit 2x
//         vm.prank(users[2]);
//         IEToken(tokens[1]).mint(100 ether);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 3112);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 24889);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 34666);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 29334);

//         // user0, user1, user2, user3 claims
//         vm.prank(users[0]);
//         gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
//         vm.prank(users[1]);
//         gaugeManager.claim(_makeTokenArray(tokens[0]), users[1]);
//         vm.prank(users[2]);
//         gaugeManager.claim(_makeTokenArray(tokens[1]), users[2]);
//         vm.prank(users[3]);
//         gaugeManager.claim(_makeTokenArray(tokens[1]), users[3]);

//         assertEq(cve.balanceOf(users[0]), 15111);
//         assertEq(cve.balanceOf(users[1]), 24889);
//         assertEq(cve.balanceOf(users[2]), 34666);
//         assertEq(cve.balanceOf(users[3]), 45334);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 1111);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 8889);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[2]), 6667);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 13333);
//     }

//     function testClaim() public {
//         address[] memory listedTokens = marketManagerIsolated.queryTokensListed();
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user0 deposit 100 token1
//         vm.prank(users[0]);
//         IEToken(tokens[1]).mint(100 ether);

//         vm.warp(gaugeManager.gaugeStartTime());
//         _skipEpochDuration(1);

//         vm.roll(block.number + 1000);

//         // set gauge weights
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100 * 2 weeks;
//         poolWeights[1] = 200 * 2 weeks;

//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//         vm.prank(address(messagingHub));
//         cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

//         mockDaiFeed.setMockUpdatedAt(block.timestamp);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 9999);

//         // user1 deposit 400 token0
//         vm.prank(users[1]);
//         IEToken(tokens[0]).mint(400 ether);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // user3 deposit 400 token1
//         vm.prank(users[3]);
//         IEToken(tokens[1]).mint(400 ether);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 11999);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 8000);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 16000);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // user0, user3 claims
//         vm.prank(users[0]);
//         gaugeManager.claim(listedTokens, users[0]);
//         vm.prank(users[3]);
//         gaugeManager.claim(listedTokens, users[3]);

//         assertEq(cve.balanceOf(users[0]), 35998);
//         assertEq(cve.balanceOf(users[3]), 16000);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 2000);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 16000);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 16000);

//         // user0 withdraw half
//         vm.prank(users[0]);
//         IEToken(tokens[0]).redeem(50 ether, address(this));

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 3112);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 24889);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 32000);

//         // user0, user1, user2, user3 claims with empty array
//         vm.prank(users[0]);
//         gaugeManager.claim(new address[](0), users[0]);
//         vm.prank(users[1]);
//         gaugeManager.claim(new address[](0), users[1]);
//         vm.prank(users[3]);
//         gaugeManager.claim(new address[](0), users[3]);

//         // user0, user1, user2, user3 claims listedTokens(multi token)
//         vm.prank(users[0]);
//         gaugeManager.claim(listedTokens, users[0]);
//         vm.prank(users[1]);
//         gaugeManager.claim(listedTokens, users[1]);
//         vm.prank(users[3]);
//         gaugeManager.claim(listedTokens, users[3]);

//         assertEq(cve.balanceOf(users[0]), 47110);
//         assertEq(cve.balanceOf(users[1]), 24889);
//         assertEq(cve.balanceOf(users[3]), 48000);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 1111);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 8889);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 16000);
//     }

//     function testClaimWithDelegation() public {
//         address[] memory listedTokens = marketManagerIsolated.queryTokensListed();
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user0 deposit 100 token1
//         vm.prank(users[0]);
//         IEToken(tokens[1]).mint(100 ether);

//         vm.warp(gaugeManager.gaugeStartTime());
//         _skipEpochDuration(1);

//         vm.roll(block.number + 1000);

//         // set gauge weights
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 100 * 2 weeks;
//         poolWeights[1] = 200 * 2 weeks;

//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
//         vm.prank(address(messagingHub));
//         cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

//         mockDaiFeed.setMockUpdatedAt(block.timestamp);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 9999);

//         // user1 deposit 400 token0
//         vm.prank(users[1]);
//         IEToken(tokens[0]).mint(400 ether);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // user3 deposit 400 token1
//         vm.prank(users[3]);
//         IEToken(tokens[1]).mint(400 ether);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 11999);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[1]), 8000);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[3]), 16000);

//         gaugeManager.updatePool(tokens[0]);
//         gaugeManager.updatePool(tokens[1]);

//         // try to claim without delegation and revert
//         vm.prank(users[4]);
//         // reverts with PluginDelegable__Unauthorized.selector
//         vm.expectRevert(0xcfdc5602);
//         gaugeManager.claim(listedTokens, users[0]);

//         vm.prank(users[0]);
//         gaugeManager.setDelegateApproval(users[4], true);
//         vm.prank(users[3]);
//         gaugeManager.setDelegateApproval(users[4], true);
//         // user4 claims for user0, user3
//         vm.prank(users[4]);
//         gaugeManager.claim(listedTokens, users[0]);

//         assertEq(cve.balanceOf(users[4]), 35998);
//         vm.prank(users[4]);
//         gaugeManager.claim(listedTokens, users[3]);

//         assertEq(cve.balanceOf(users[4]), 35998 + 16000);
//     }

//     function testZach_RevertOnSecondDeposit() public {
//         // set up emission rates and fund the gauge pool with cve
//         address mToken = tokens[0];
//         address[] memory tokensParam = new address[](1);
//         tokensParam[0] = mToken;
//         uint256[] memory poolWeights = new uint256[](1);
//         poolWeights[0] = 1e18;
//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);
//         _prepareCVE(address(gaugeManager), 1e18);

//         vm.startPrank(mToken);

//         // make a deposit before start time
//         gaugeManager.deposit(mToken, address(this), 100 ether);

//         // make a withdrawal before start time
//         gaugeManager.withdraw(mToken, address(this), 100 ether);

//         // fast forward to after start time
//         vm.warp(gaugeManager.gaugeStartTime() + 2 weeks);

//         // make a deposit after start time
//         gaugeManager.deposit(mToken, address(this), 100 ether);

//         // make a withdrawal after start time
//         gaugeManager.withdraw(mToken, address(this), 100 ether);

//         vm.stopPrank();
//     }

//     function testZach_ZeroCollRatio() public {
//         _deployPBALRETH();
//         _prepareBALRETH(address(this), 1 ether);

//         balRETH.approve(address(pBALRETH), 1 ether);
//         marketManagerIsolated.listToken(address(pBALRETH));

//         oracleManager.addMTokenSupport(address(pBALRETH));

//         // set collateral factor
//         marketManagerIsolated.updatePositionToken(
//             address(pBALRETH),
//             0,
//             4000,
//             3000,
//             200,
//             400,
//             1000
//         );

//         // set up emission rates and fund the gauge pool with cve
//         address[] memory tokensParam = new address[](1);
//         tokensParam[0] = address(pBALRETH);
//         uint256[] memory poolWeights = new uint256[](1);
//         poolWeights[0] = 1e18;
//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);
//         _prepareCVE(address(gaugeManager), 1e18);

//         vm.startPrank(address(pBALRETH));

//         // make a deposit before start time
//         gaugeManager.deposit(address(pBALRETH), address(this), 1 ether);

//         // make a withdrawal before start time
//         gaugeManager.withdraw(address(pBALRETH), address(this), 1 ether);

//         // fast forward to after start time
//         vm.warp(gaugeManager.gaugeStartTime() + 2 weeks);

//         // make a deposit after start time
//         gaugeManager.deposit(address(pBALRETH), address(this), 1 ether);

//         // make a withdrawal after start time
//         gaugeManager.withdraw(address(pBALRETH), address(this), 1 ether);

//         vm.stopPrank();
//     }

//     function testRedeemRevertInvalidAmount() public {
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user0 withdraw half
//         vm.prank(users[0]);
//         vm.expectRevert();
//         IEToken(tokens[0]).redeem(100 ether + 1, address(this));
//     }

//     // Deploy ETokenWithGauge
//     function _deployEToken(
//         address token
//     ) internal override initMainVariables returns (EToken) {
//         EToken eToken = EToken(
//             address(
//                 new ETokenWithGauge(
//                     ICentralRegistry(address(centralRegistry)),
//                     token,
//                     address(marketManagerIsolated),
//                     _deployDynamicInterestRateModel(token)
//                 )
//             )
//         );

//         interestRateModels[block.chainid][token].setLinkedEToken(
//             address(eToken)
//         );

//         return eToken;
//     }
// }