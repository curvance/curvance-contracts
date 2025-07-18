// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BorrowableCTokenWithGauge } from "contracts/market/token/withGauge/BorrowableCTokenWithGauge.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract User {}

contract TestGaugeManager_DoubleGauge is TestBaseMarketIsolated {
    address public owner;
    address public borrowableCDAIWithGauge;
    address public borrowableCUSDCWithGauge;
    address[] public users;

    MockDataFeed public mockDaiFeed;

    function setUp() public override {
        super.setUp();
        users = new address[](10);

        // prepare 200K USDC and DAI
        _prepareUSDC(user1, 200000e6);
        _prepareUSDC(user2, 200000e6);
        _prepareUSDC(liquidator, 200000e6);
        _prepareUSDC(address(this), 77777);

        _prepareDAI(user1, 200000e18);
        _prepareDAI(user2, 200000e18);
        _prepareDAI(liquidator, 200000e18);
        _prepareDAI(address(this), 200000e18);

        owner = address(this);
        _prepareDAI(owner, 200000e18);

        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(new User());
            _prepareDAI(users[i], 200000e18);
        }

        borrowableCDAIWithGauge = address( new BorrowableCTokenWithGauge(
            ICentralRegistry(address(centralRegistry)),
            IERC20(dai),
            address(marketManagerIsolated),
            _deployDynamicInterestRateModel(address(dai))
        )); 
        borrowableCUSDCWithGauge = address( new BorrowableCTokenWithGauge(
            ICentralRegistry(address(centralRegistry)),
            IERC20(usdc),
            address(marketManagerIsolated),
            _deployDynamicInterestRateModel(address(usdc))
        )); 

        // Link the interest rate models to the tokens
        interestRateModels[block.chainid][address(dai)].setLinkedToken(borrowableCDAIWithGauge);
        interestRateModels[block.chainid][address(usdc)].setLinkedToken(borrowableCUSDCWithGauge);

        dai.approve(borrowableCDAIWithGauge, 77777);
        usdc.approve(borrowableCUSDCWithGauge, 77777);
        // List the token pair in the market
        marketManagerIsolated.listTokens(borrowableCDAIWithGauge, borrowableCUSDCWithGauge);

        // Setup approvals for owner
        dai.approve(borrowableCDAIWithGauge, 200000e18);
        usdc.approve(borrowableCUSDCWithGauge, 200000e18);

        // Setup approvals for all users
        for (uint256 j = 0; j < 10; j++) {
            address user = users[j];
            _prepareDAI(user, 200000e18);
            _prepareUSDC(user, 200000e18);
            
            vm.prank(user);
            dai.approve(borrowableCDAIWithGauge, 200000e18);
            vm.prank(user);
            usdc.approve(borrowableCUSDCWithGauge, 200000e18);
        }

        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
    }

    function testClaim() public {

        // user0 deposit 100 borrowableCUSDCWithGauge
        vm.prank(users[0]);
        IBorrowableCToken(borrowableCUSDCWithGauge).deposit(100e6, users[0]);
        
        // user0 deposit 100 borrowableCDAIWithGauge
        vm.prank(users[0]);
        IBorrowableCToken(borrowableCDAIWithGauge).deposit(100 ether, users[0]);



        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);

        vm.roll(block.number + 1000);

        // set gauge weights
        // only borrowable token has gauge functionality
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = borrowableCUSDCWithGauge;
        tokensParam[1] = borrowableCDAIWithGauge;
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100 * 2 weeks;
        poolWeights[1] = 200 * 2 weeks;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        gaugeManager.updatePool(borrowableCUSDCWithGauge);
        gaugeManager.updatePool(borrowableCDAIWithGauge);


        // user0 usdc: 29,999 * ((100/100) * (100/300)) = 9999.666666666666666666 (rounds down to 9992)
        // user0 dai: 29,999 * ((100/100) * (200/300)) = 19999.333333333333333333 (rounds down to 19999)
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[0]), 9992);
        assertEq(gaugeManager.pendingRewards(borrowableCDAIWithGauge, users[0]), 19999);
        
        // user1 deposit 400 borrowableCUSDCWithGauge
        vm.prank(users[1]);
        IBorrowableCToken(borrowableCUSDCWithGauge).deposit(400e6, users[1]);

        // update pool only for borrowable token
        gaugeManager.updatePool(borrowableCUSDCWithGauge);
        gaugeManager.updatePool(borrowableCDAIWithGauge);

        // user2 deposit 400 borrowableCUSDCWithGauge
        vm.prank(users[2]);
        IBorrowableCToken(borrowableCUSDCWithGauge).deposit(400e6, users[2]);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        // user0 usdc: 9999 + (29,999 * ((100/900) * (100/300))) = 1111 + 9999 = 11110
        // user0 dai: 19999 + (29,999 * ((100/100) * (200/300))) = 19999 + 19999 = 39998
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[0]), 11110);
        assertEq(gaugeManager.pendingRewards(borrowableCDAIWithGauge, users[0]), 39998);

        // user1 usdc: (29,999 * ((400/900) * (100/300))) = 4444
        // user2 usdc: (29,999 * ((400/900) * (100/300))) = 4444
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[1]), 4444);
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[2]), 4444);

        gaugeManager.updatePool(borrowableCDAIWithGauge);
        gaugeManager.updatePool(borrowableCUSDCWithGauge);

        // user0, user2 claims
        vm.prank(users[0]);
        gaugeManager.claim(tokensParam, users[0]);
        vm.prank(users[2]);
        gaugeManager.claim(tokensParam, users[2]);

        assertEq(cve.balanceOf(users[0]), 51108);
        assertEq(cve.balanceOf(users[2]), 4444);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        // user0 usdc: (29,999 * ((100/900) * (100/300))) = 1111
        // user0 dai: (29,999 * ((100/100) * (200/300))) = 19999
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[0]), 1111);
        assertEq(gaugeManager.pendingRewards(borrowableCDAIWithGauge, users[0]), 19999);

        // user1 usdc: 4444 + (29,999 * ((400/900) * (100/300))) = 4444 + 4444 = 8888
        // user2 usdc: (29,999 * ((400/900) * (100/300))) = 4444
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[1]), 8888);
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[2]), 4444);

        // user0 withdraw half
        vm.prank(users[0]);
        IBorrowableCToken(borrowableCUSDCWithGauge).redeem(50e6, users[0], users[0]);

        gaugeManager.updatePool(borrowableCDAIWithGauge);
        gaugeManager.updatePool(borrowableCUSDCWithGauge);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[0]), 0);
        assertEq(gaugeManager.pendingRewards(borrowableCDAIWithGauge, users[0]), 0);

        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[1]), 0);
        assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[2]), 0);

        // // user0, user1, user3 claims
        // vm.prank(users[0]);
        // gaugeManager.claim(listedTokens, users[0]);
        // vm.prank(users[1]);
        // gaugeManager.claim(listedTokens, users[1]);
        // vm.prank(users[3]);
        // gaugeManager.claim(listedTokens, users[3]);

        // // User0: 33333 + 5098 = 38431
        // // User1: 26667 + 14118 = 40785
        // // User2: 13334 + 27451 = 40785
        // assertEq(cve.balanceOf(users[0]), 38431); 
        // assertEq(cve.balanceOf(users[1]), 40785); 
        // assertEq(cve.balanceOf(users[3]), 40785); 

        // gaugeManager.updatePool(borrowableCDAIWithGauge);
        // gaugeManager.updatePool(borrowableCUSDCWithGauge);

        // // check pending rewards after 100 seconds
        // vm.warp(block.timestamp + 100);

        // gaugeManager.updatePool(borrowableCDAIWithGauge);
        // gaugeManager.updatePool(borrowableCUSDCWithGauge);

        // // User0: ((50/(50+400+400)) * 30000) = 1764.70 (rounds down)
        // // User1: ((400/(50+400+400)) * 30000) = 14117.64
        // // User2: ((400/(50+400+400)) * 30000) = 14117.64
        // assertEq(gaugeManager.pendingRewards(borrowableCDAIWithGauge, users[0]), 1764); 
        // assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[1]), 14117); 
        // assertEq(gaugeManager.pendingRewards(borrowableCUSDCWithGauge, users[3]), 14117); 
    }

}