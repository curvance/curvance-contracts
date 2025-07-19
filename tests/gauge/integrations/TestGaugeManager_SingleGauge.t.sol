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

contract TestGaugeManager_SingleGauge is TestBaseMarketIsolated {
    address public owner;
    address public collateralToken;
    address public borrowableToken;
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

        // prepare BAL-RETH for collateral, not really needed
        // because we won't use gauge for collateral
        _prepareBALRETH(user1, 1 ether);
        _prepareBALRETH(user2, 1 ether);
        _prepareBALRETH(liquidator, 1 ether);
        _prepareBALRETH(address(this), 77777);

        owner = address(this);
        _prepareDAI(owner, 200000e18);

        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(new User());
            _prepareDAI(users[i], 200000e18);
        }

        collateralToken = address(strategyCBALRETH);  // No gauge functionality
        borrowableToken = address(borrowableCDAI);    // Has gauge functionality

        balRETH.approve(collateralToken, 77777);
        dai.approve(borrowableToken, 77777);
        // List the token pair in the market
        marketManagerIsolated.listTokens(collateralToken, borrowableToken);

        // Setup approvals for owner
        dai.approve(borrowableToken, 200000e18);
        balRETH.approve(collateralToken, 200000e18);

        // Setup approvals for all users
        for (uint256 j = 0; j < 10; j++) {
            address user = users[j];
            _prepareDAI(user, 200000e18);
            _prepareBALRETH(user, 200000e18);
            
            vm.prank(user);
            dai.approve(borrowableToken, 200000e18);
            vm.prank(user);
            balRETH.approve(collateralToken, 200000e18);
        }

        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
    }

    function testRevertLockStartTimeBeforeGenesisEpoch() public {
        uint256 genesisEpoch = centralRegistry.genesisEpoch();
        vm.warp(genesisEpoch - 1000);

        vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
        gaugeManager.lockInStartTime();
    }

    function testStartTimeShouldBeAfterLock() public {
        uint256 genesisEpoch = centralRegistry.genesisEpoch();
        uint256 epochDuration = gaugeManager.epochDuration();
        vm.warp(genesisEpoch + 1000);

        uint256 gaugeStartTimeBefore = gaugeManager.gaugeStartTime();
        assertEq(
            gaugeStartTimeBefore,
            genesisEpoch +
                (((block.timestamp - genesisEpoch) / epochDuration) *
                    epochDuration)
        );

        gaugeManager.lockInStartTime();
        uint256 gaugeStartTimeAfter = gaugeManager.gaugeStartTime();
        assertEq(gaugeStartTimeBefore, gaugeStartTimeAfter);
    }

    function testRevertSetEmissionRatesUnauthorized() public {
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        // set gauge settings of next epoch
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100;
        poolWeights[1] = 200;

        vm.expectRevert(GaugeManager.GaugeManager__Unauthorized.selector);
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
    }

    function testRevertSetEmissionRatesInvalidEpoch() public {
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        // set gauge settings of next epoch
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100;
        poolWeights[1] = 200;

        vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(2, tokensParam, poolWeights);
    }

    function testRevertSetEmissionRatesInvalidLength() public {
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        // set gauge settings of next epoch
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 100;

        vm.prank(address(messagingHub));

        vm.expectRevert(GaugeManager.GaugeManager__InvalidLength.selector);
        gaugeManager.setEmissionRates(0, tokensParam, poolWeights);
    }

    function testRevertSetEmissionRatesInvalidToken() public {
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        // set gauge settings of next epoch
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = borrowableToken;
        tokensParam[1] = collateralToken;
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100;
        poolWeights[1] = 200;

        vm.prank(address(messagingHub));

        vm.expectRevert(GaugeManager.GaugeManager__InvalidToken.selector);
        gaugeManager.setEmissionRates(0, tokensParam, poolWeights);
    }

    function testIsGaugeEnabled() public {
        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);

        vm.roll(block.number + 1000);

        // set gauge settings of next epoch
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100;
        poolWeights[1] = 200;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);

        assertEq(gaugeManager.isGaugeEnabled(1, collateralToken), true);
        assertEq(gaugeManager.isGaugeEnabled(1, address(borrowableCUSDC)), false);
    }

    function testManageEmissionRatesOfEachEpoch() public {
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        assertEq(gaugeManager.currentEpoch(), 0);
        assertEq(gaugeManager.epochOfTimestamp(block.timestamp + 3 weeks), 1);
        assertEq(gaugeManager.epochStartTime(1), block.timestamp + 2 weeks);
        assertEq(gaugeManager.epochEndTime(1), block.timestamp + 4 weeks);

        // set gauge settings of current epoch
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100;
        poolWeights[1] = 200;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

        (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
            0,
            collateralToken
        );
        assertEq(totalWeights, 300);
        assertEq(poolWeight, 100);
        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, borrowableToken);
        assertEq(totalWeights, 300);
        assertEq(poolWeight, 200);
    }

    function testSecondEmissionRatesSetOfEachEpoch() public {
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        assertEq(gaugeManager.currentEpoch(), 0);
        assertEq(gaugeManager.epochOfTimestamp(block.timestamp + 3 weeks), 1);
        assertEq(gaugeManager.epochStartTime(1), block.timestamp + 2 weeks);
        assertEq(gaugeManager.epochEndTime(1), block.timestamp + 4 weeks);

        // set gauge settings of current epoch
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100;
        poolWeights[1] = 200;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

        (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
            0,
            collateralToken
        );
        assertEq(totalWeights, 300);
        assertEq(poolWeight, 100);
        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, borrowableToken);
        assertEq(totalWeights, 300);
        assertEq(poolWeight, 200);

        poolWeights[0] = 200;
        poolWeights[1] = 100;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, collateralToken);
        assertEq(totalWeights, 600);
        assertEq(poolWeight, 300);
        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, borrowableToken);
        assertEq(totalWeights, 600);
        assertEq(poolWeight, 300);
    }

    function testCanOnlyUpdateEmissionRatesOfNextEpoch() public {
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        assertEq(gaugeManager.currentEpoch(), 0);
        assertEq(gaugeManager.epochOfTimestamp(block.timestamp + 3 weeks), 1);
        assertEq(gaugeManager.epochStartTime(1), block.timestamp + 2 weeks);
        assertEq(gaugeManager.epochEndTime(1), block.timestamp + 4 weeks);

        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 100;
        poolWeights[1] = 200;

        // check invalid epoch
        vm.startPrank(address(messagingHub));

        vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.expectRevert(GaugeManager.GaugeManager__InvalidEpoch.selector);
        gaugeManager.setEmissionRates(2, tokensParam, poolWeights);

        // can update emission rate of current epoch
        gaugeManager.setEmissionRates(0, tokensParam, poolWeights);

        vm.stopPrank();

        (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
            0,
            collateralToken
        );
        assertEq(totalWeights, 300);
        assertEq(poolWeight, 100);
        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(0, borrowableToken);
        assertEq(totalWeights, 300);
        assertEq(poolWeight, 200);
    }

    function testRevertDepositInvalidToken() public {
        vm.expectRevert(GaugeManager.GaugeManager__InvalidToken.selector);
        gaugeManager.deposit(collateralToken, address(this), 100 ether);

        vm.expectRevert(GaugeManager.GaugeManager__InvalidToken.selector);
        gaugeManager.withdraw(collateralToken, address(this), 100 ether);
    }

    function testRevertClaim() public {
        vm.warp(gaugeManager.gaugeStartTime() - 1);

        vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
        vm.prank(users[0]);
        gaugeManager.claim(_makeTokenArray(address(cve)), users[0]);
    }

    function testEmptyClaim() public {
        vm.warp(gaugeManager.gaugeStartTime());

        vm.prank(users[0]);
        gaugeManager.claim(new address[](0), users[0]);
    }

    function testRewardCalculationWithDifferentEpoch() public {
        // user0 deposit 100 collateralToken
        vm.prank(users[0]);
        IBorrowableCToken(collateralToken).deposit(100 ether, users[0]);

        // user1 deposit 100 borrowableToken
        vm.prank(users[1]);
        IBorrowableCToken(borrowableToken).deposit(100 ether, users[1]);

        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        vm.startPrank(address(messagingHub));

        // set gauge weights
        address[] memory tokensParam = new address[](1);
        tokensParam[0] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 300 * 2 weeks;

        _skipEpochDuration(1);

        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 29999);

        // set gauge weights for next epoch
        tokensParam[0] = borrowableToken;
        poolWeights[0] = 400 * 2 weeks;

        _skipEpochDuration(1);

        gaugeManager.setEmissionRates(2, tokensParam, poolWeights);
        cve.mintGaugeEmissions(address(gaugeManager), 400 * 2 weeks);

        vm.stopPrank();

        // check pending rewards after 2 weeks
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        assertEq(
            gaugeManager.pendingRewards(borrowableToken, users[1]),
            2 weeks * 300 + 100 * 400 - 1
        );

        // user1 claim rewards
        vm.prank(users[1]);
        gaugeManager.claim(_makeTokenArray(borrowableToken), users[1]);

        assertEq(cve.balanceOf(users[1]), 2 weeks * 300 + 100 * 400 - 1);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 0);
    }

    function testMassUpdatePoolDoesNotMessUpTheRewardCalculation() public {
        // user0 deposit 100 collateralToken
        vm.prank(users[0]);
        IBorrowableCToken(collateralToken).deposit(100 ether, users[0]);

        // user2 deposit 100 borrowableToken
        vm.prank(users[2]);
        IBorrowableCToken(borrowableToken).deposit(100 ether, users[2]);

        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);

        vm.roll(block.number + 1000);

        // set gauge weights
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
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
        gaugeManager.massUpdatePools(tokensParam);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[2]), 19999);
    }

    function testPendingRewardsReturnsAllRewards() public {
        // user0 deposit 100 collateralToken
        vm.prank(users[0]);
        IBorrowableCToken(collateralToken).deposit(100 ether, users[0]);

        // user2 deposit 100 borrowableToken
        vm.prank(users[2]);
        IBorrowableCToken(borrowableToken).deposit(100 ether, users[2]);

        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);

        vm.roll(block.number + 1000);

        // set gauge weights
        address[] memory tokensParam = new address[](2);
        tokensParam[0] = collateralToken;
        tokensParam[1] = borrowableToken;
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
        gaugeManager.massUpdatePools(tokensParam);
        // uint256[] memory rewards = gaugeManager.pendingRewards(
        //     _makeTokenArray(collateralToken),
        //     users[0]
        // );
        // assertEq(rewards[0], 9999);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[2]), 19999);
    }

    function testUpdatePoolDoesNotMessUpTheRewardCalculation() public {
        // user0 deposit 100 borrowableToken, not necessary for the test
        vm.prank(users[0]);
        IBorrowableCToken(borrowableToken).deposit(100 ether, users[0]);

        // user2 deposit 100 borrowableToken
        vm.prank(users[2]);
        IBorrowableCToken(borrowableToken).deposit(100 ether, users[2]);

        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);

        vm.roll(block.number + 1000);

        // set gauge weights
        address[] memory tokensParam = new address[](1);
        tokensParam[0] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 300 * 2 weeks;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        gaugeManager.updatePool(borrowableToken);

        // 30000 total rewards, 200 total tokens
        // user0: (100 / 200) * 30000 = 15000
        // user2: (100 / 200) * 30000 = 15000
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 14999);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[2]), 14999);


        // user1 deposit 400 borrowableToken
        vm.prank(users[1]);
        IBorrowableCToken(borrowableToken).deposit(400 ether, users[1]);

        gaugeManager.updatePool(borrowableToken);

        // user3 deposit 400 borrowableToken
        vm.prank(users[3]);
        IBorrowableCToken(borrowableToken).deposit(400 ether, users[3]);

        // check pending rewards after 100 seconds
        // New total (100 + 100 + 400 + 400) = 10,000 tokens
        vm.warp(block.timestamp + 100);

        // User0:(100 / 1000) * 30,000 = 300 + 15000
        // User1:(400 / 1000) * 30,000 = 1200
        // User2:(100 / 1000) * 30,000 = 300 + 15000
        // User3:(400 / 1000) * 30,000 = 1200

        // This assert is off due to rounding, should be 18000.
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 17999);
        // This assert is off due to rounding, should be 18000.
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 12000);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[2]), 17999);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 12000);

        gaugeManager.updatePool(borrowableToken);

        // user0, user3 claims
        vm.prank(users[0]);
        gaugeManager.claim(_makeTokenArray(borrowableToken), users[0]);
        vm.prank(users[3]);
        gaugeManager.claim(_makeTokenArray(borrowableToken), users[3]);

        assertEq(cve.balanceOf(users[0]), 17999);
        assertEq(cve.balanceOf(users[3]), 12000);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        // User0:(100 / 1000) * 30,000 = 3000
        // User1:(400 / 1000) * 30,000 = 12000 + 12000 = 24000
        // User2:(100 / 1000) * 30,000 = 3000 + 18000 = 21000
        // User3:(400 / 1000) * 30,000 = 12000 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 3000);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 24000);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[2]), 20999); // rounds up
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 12000);

        // user0 withdraw half
        vm.prank(users[0]);
        IBorrowableCToken(borrowableToken).redeem(50 ether, users[0], users[0]);

        // user2 deposit 2x
        vm.prank(users[2]);
        IBorrowableCToken(borrowableToken).deposit(100 ether, users[2]);

        gaugeManager.updatePool(borrowableToken);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        // User0: (50 / 1050) * 30,000 = 1428.57 + 3000 = 4428.57 
        // User1: (400 / 1050) * 30,000 = 11428.57 + 24000 = 35428.57
        // User2: (200 / 1050) * 30,000 = 5714.28 + 20999 = 26713.28
        // User3: (400 / 1050) * 30,000 = 11428.57 + 12000 = 23428.57
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 4429); // rounds up
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 35429); // rounds up
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[2]), 26714);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 23429);

        // user0, user1, user2, user3 claims
        vm.prank(users[0]);
        gaugeManager.claim(_makeTokenArray(borrowableToken), users[0]);
        vm.prank(users[1]);
        gaugeManager.claim(_makeTokenArray(borrowableToken), users[1]);
        vm.prank(users[2]);
        gaugeManager.claim(_makeTokenArray(borrowableToken), users[2]);
        vm.prank(users[3]);
        gaugeManager.claim(_makeTokenArray(borrowableToken), users[3]);

        assertEq(cve.balanceOf(users[0]), 22428); // 17999 + 4429
        assertEq(cve.balanceOf(users[1]), 35429);
        assertEq(cve.balanceOf(users[2]), 26714);
        assertEq(cve.balanceOf(users[3]), 35429);

        gaugeManager.updatePool(borrowableToken);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        gaugeManager.updatePool(borrowableToken);

        // User0: (50 / 1050) * 30,000 = 1428.57
        // User1: (400 / 1050) * 30,000 = 11428.57 
        // User2: (200 / 1050) * 30,000 = 5714.28 
        // User3: (400 / 1050) * 30,000 = 11428.57 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 1429);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 11429);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[2]), 5714);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 11429);
    }

    function testClaim() public {
        address[] memory listedTokens = marketManagerIsolated.queryTokensListed();
        
        // user0 deposit 100 borrowableToken
        vm.prank(users[0]);
        IBorrowableCToken(borrowableToken).deposit(100 ether, users[0]);

        // user0 can also deposit into collateralToken (for market completeness) but no gauge rewards
        vm.prank(users[0]);
        IBorrowableCToken(collateralToken).deposit(100 ether, users[0]);

        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);

        vm.roll(block.number + 1000);

        // set gauge weights
        // only borrowable token has gauge functionality
        address[] memory tokensParam = new address[](1);
        tokensParam[0] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 300 * 2 weeks;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        gaugeManager.updatePool(borrowableToken);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 29999); // 100% of rewards since only 1 user

        // user1 deposit 400 borrowableToken
        vm.prank(users[1]);
        IBorrowableCToken(borrowableToken).deposit(400 ether, users[1]);

        // update pool only for borrowable token
        gaugeManager.updatePool(borrowableToken);

        // user3 deposit 400 borrowableToken
        vm.prank(users[3]);
        IBorrowableCToken(borrowableToken).deposit(400 ether, users[3]);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        // User0: ((100/(100+400+400)) * 30000) + 29999 = 3333 + 29999 = 33332
        // User1: ((400/(100+400+400)) * 30000) = 13333 + 1 (rounding)
        // User2: ((400/(100+400+400)) * 30000) = 13333 + 1 (rounding)
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 33333);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 13334); 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 13334);

        gaugeManager.updatePool(borrowableToken);

        // user0, user3 claims
        vm.prank(users[0]);
        gaugeManager.claim(listedTokens, users[0]);
        vm.prank(users[3]);
        gaugeManager.claim(listedTokens, users[3]);

        assertEq(cve.balanceOf(users[0]), 33333);
        assertEq(cve.balanceOf(users[3]), 13334);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        // User0: ((100/(100+400+400)) * 30000) = 3333
        // User1: ((400/(100+400+400)) * 30000 * 2) = 26666 + 1 (rounding)
        // User2: ((400/(100+400+400)) * 30000) = 13333
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 3333); 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 26667); 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 13333); 

        // user0 withdraw half
        vm.prank(users[0]);
        IBorrowableCToken(borrowableToken).redeem(50 ether, users[0], users[0]);

        gaugeManager.updatePool(borrowableToken);

        // check pending rewards after 100 seconds  
        // Now total is 850 (50 + 400 + 400)
        vm.warp(block.timestamp + 100);

        // User0: ((50/(50+400+400)) * 30000) + 3333 = 1765 + 3333 = 5098
        // User1: ((400/(50+400+400)) * 30000) + 26667 = 14118 + 26667 = 40785
        // User3: ((400/(50+400+400)) * 30000) + 13333 = 14118 + 13333 = 27451
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 5098); 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 40785); 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 27451); 

        // user0, user1, user3 claims
        vm.prank(users[0]);
        gaugeManager.claim(listedTokens, users[0]);
        vm.prank(users[1]);
        gaugeManager.claim(listedTokens, users[1]);
        vm.prank(users[3]);
        gaugeManager.claim(listedTokens, users[3]);

        // User0: 33333 + 5098 = 38431
        // User1: 26667 + 14118 = 40785
        // User2: 13334 + 27451 = 40785
        assertEq(cve.balanceOf(users[0]), 38431); 
        assertEq(cve.balanceOf(users[1]), 40785); 
        assertEq(cve.balanceOf(users[3]), 40785); 

        gaugeManager.updatePool(borrowableToken);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        gaugeManager.updatePool(borrowableToken);

        // User0: ((50/(50+400+400)) * 30000) = 1764.70 (rounds down)
        // User1: ((400/(50+400+400)) * 30000) = 14117.64
        // User2: ((400/(50+400+400)) * 30000) = 14117.64
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 1764); 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 14117); 
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 14117); 
    }

    function testClaimWithDelegation() public {
        address[] memory listedTokens = marketManagerIsolated.queryTokensListed();
        // user0 deposit 100 collateralToken
        vm.prank(users[0]);
        IBorrowableCToken(collateralToken).deposit(100 ether, users[0]);

        // user0 deposit 100 borrowableToken
        vm.prank(users[0]);
        IBorrowableCToken(borrowableToken).deposit(100 ether, users[0]);

        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);

        vm.roll(block.number + 1000);

        // set gauge weights
        address[] memory tokensParam = new address[](1);
        tokensParam[0] = borrowableToken;
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 300 * 2 weeks;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        gaugeManager.updatePool(borrowableToken);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 29999);

        vm.prank(users[1]);
        IBorrowableCToken(borrowableToken).deposit(400 ether, users[1]);

        gaugeManager.updatePool(borrowableToken);

        // user3 deposit 400 borrowableToken
        vm.prank(users[3]);
        IBorrowableCToken(borrowableToken).deposit(400 ether, users[3]);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[0]), 33333);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[1]), 13334);
        assertEq(gaugeManager.pendingRewards(borrowableToken, users[3]), 13334);

        gaugeManager.updatePool(borrowableToken);

        // try to claim without delegation and revert
        vm.prank(users[4]);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(bytes("PluginDelegable__Unauthorized()"));
        gaugeManager.claim(listedTokens, users[0]);

        vm.prank(users[0]);
        gaugeManager.setDelegateApproval(users[4], true);
        vm.prank(users[3]);
        gaugeManager.setDelegateApproval(users[4], true);
        // user4 claims for user0, user3
        vm.prank(users[4]);
        gaugeManager.claim(listedTokens, users[0]);

        assertEq(cve.balanceOf(users[4]), 33333);
        vm.prank(users[4]);
        gaugeManager.claim(listedTokens, users[3]);

        assertEq(cve.balanceOf(users[4]), 33333 + 13334);
    }

    function testRedeemRevertInvalidAmount() public {
        // user0 deposit 100 collateralToken
        vm.prank(users[0]);
        IBorrowableCToken(collateralToken).deposit(100 ether, users[0]);

        // user0 withdraw half
        vm.prank(users[0]);
        vm.expectRevert();
        IBorrowableCToken(collateralToken).redeem(100 ether + 1, users[0], users[0]);
    }

    // Deploy ETokenWithGauge
    function _deployBorrowableCToken(
        address token
    ) internal override initMainVariables returns (BorrowableCToken) {
        BorrowableCToken borrowableCToken = BorrowableCToken(
            address(
                new BorrowableCTokenWithGauge(
                    ICentralRegistry(address(centralRegistry)),
                    IERC20(token),
                    address(marketManagerIsolated),
                    _deployDynamicInterestRateModel(token)
                )
            )
        );

        interestRateModels[block.chainid][token].setLinkedToken(
            address(borrowableCToken)
        );

        return borrowableCToken;
    }
}