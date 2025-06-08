// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.15;

// import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
// import { IEToken } from "contracts/interfaces/IEToken.sol";
// import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
// import { MockToken } from "contracts/mocks/MockToken.sol";
// import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

// contract User {}

// // FIX
// contract TestGaugeEdgeCase is TestBaseMarketIsolated {
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

//     function testCannotRedeemMoreThanDeposit() public {
//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user0 withdraw half
//         vm.prank(users[0]);
//         vm.expectRevert();
//         IEToken(tokens[0]).redeem(101 ether, address(this));
//     }

//     function testCanDepositWithdrawBeforeGaugeStartTime() public {
//         // start epoch

//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user1 deposit 100 token1
//         vm.prank(users[1]);
//         IEToken(tokens[1]).mint(100 ether);

//         // user0 withdraw half
//         vm.prank(users[0]);
//         IEToken(tokens[0]).redeem(50 ether, address(this));
//     }

//     function testCanDepositWithdrawAfterGaugeStartTime() public {
//         // start epoch

//         vm.warp(gaugeManager.gaugeStartTime() + 10 seconds);
//         vm.roll(block.number + 1000);

//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user1 deposit 100 token1
//         vm.prank(users[1]);
//         IEToken(tokens[1]).mint(100 ether);

//         // user0 withdraw half
//         vm.prank(users[0]);
//         IEToken(tokens[0]).redeem(50 ether, address(this));
//     }

//     function testClaimWhenCVERewardIsZero() public {
//         address[] memory tokensParam = new address[](2);
//         tokensParam[0] = tokens[0];
//         tokensParam[1] = tokens[1];
//         uint256[] memory poolWeights = new uint256[](2);
//         poolWeights[0] = 0;
//         poolWeights[1] = 0;

//         vm.prank(address(messagingHub));
//         gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

//         vm.warp(gaugeManager.gaugeStartTime());
//         _skipEpochDuration(1);

//         mockDaiFeed.setMockUpdatedAt(block.timestamp);

//         // user0 deposit 100 token0
//         vm.prank(users[0]);
//         IEToken(tokens[0]).mint(100 ether);

//         // user1 deposit 100 token1
//         vm.prank(users[1]);
//         IEToken(tokens[1]).mint(100 ether);

//         // check pending rewards after 100 seconds
//         vm.warp(block.timestamp + 100);
//         assertEq(gaugeManager.pendingRewards(tokens[0], users[0]), 0);
//         assertEq(gaugeManager.pendingRewards(tokens[1], users[1]), 0);

//         vm.prank(users[0]);
//         gaugeManager.claim(tokens, users[0]);
//     }
// }
