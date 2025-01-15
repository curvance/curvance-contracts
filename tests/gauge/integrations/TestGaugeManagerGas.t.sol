// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { MockToken } from "contracts/mocks/MockToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract User {}

contract TestGaugePoolGas is TestBaseMarket {
    address public owner;
    address[] public tokens;
    address[] public users;

    address[100] public partnerRewardTokens;

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
        for (uint256 i = 0; i < 100; i++) {
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

        // start epoch

        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
    }

    function testGasForDepositBeforeEpochAndWithdrawInEpoch() public {
        assertEq(gaugeManager.startTime(), block.timestamp);

        // add extra rewards
        for (uint256 i = 0; i < 100; i++) {
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                partnerRewardTokens[i],
                100 * 2 weeks
            );
        }

        uint256 gasStart;

        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        // deposit
        gasStart = gasleft();
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(10 ether);
        uint256 gasUsedForDeposit = gasStart - gasleft();

        // start epoch 1
        vm.warp(gaugeManager.startTime() + 1 * 2 weeks);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        address[] memory tokensParam = new address[](1);
        tokensParam[0] = tokens[0];
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 100;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        vm.prank(users[0]);
        gasStart = gasleft();
        gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
        uint256 gasUsedForClaim = gasStart - gasleft();

        vm.prank(users[0]);
        gasStart = gasleft();
        IEToken(tokens[0]).redeem(10 ether, address(this));
        uint256 gasUsedForWithdraw = gasStart - gasleft();

        emit log_named_uint("Gas Used For Deposit", gasUsedForDeposit);
        emit log_named_uint("Gas Used For Claim", gasUsedForClaim);
        emit log_named_uint("Gas Used For Withdraw", gasUsedForWithdraw);
    }

    function testGasForDepositInEpochAndWithdrawInSameEpoch() public {
        assertEq(gaugeManager.startTime(), block.timestamp);

        // add extra rewards
        for (uint256 i = 0; i < 100; i++) {
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                partnerRewardTokens[i],
                100 * 2 weeks
            );
        }

        uint256 gasStart;

        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        // start epoch 1
        vm.warp(gaugeManager.startTime() + 1 * 2 weeks);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        address[] memory tokensParam = new address[](1);
        tokensParam[0] = tokens[0];
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 100;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);

        vm.warp(block.timestamp + 10);

        // deposit
        gasStart = gasleft();
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(10 ether);
        uint256 gasUsedForDeposit = gasStart - gasleft();

        // check pending rewards after 100 seconds
        vm.warp(block.timestamp + 100);

        vm.prank(users[0]);
        gasStart = gasleft();
        gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
        uint256 gasUsedForClaim = gasStart - gasleft();

        vm.prank(users[0]);
        gasStart = gasleft();
        IEToken(tokens[0]).redeem(10 ether, address(this));
        uint256 gasUsedForWithdraw = gasStart - gasleft();

        emit log_named_uint("Gas Used For Deposit", gasUsedForDeposit);
        emit log_named_uint("Gas Used For Claim", gasUsedForClaim);
        emit log_named_uint("Gas Used For Withdraw", gasUsedForWithdraw);
    }

    function testGasForDepositInEpochAndWithdrawAfterEpoch() public {
        assertEq(gaugeManager.startTime(), block.timestamp);

        // add extra rewards
        for (uint256 i = 0; i < 100; i++) {
            gaugeManager.addExtraRewards(
                tokens[0],
                1,
                partnerRewardTokens[i],
                100 * 2 weeks
            );
        }

        uint256 gasStart;

        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 300 * 2 weeks);

        // start epoch 1
        vm.warp(gaugeManager.startTime() + 1 * 2 weeks);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        address[] memory tokensParam = new address[](1);
        tokensParam[0] = tokens[0];
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 100;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);

        vm.warp(block.timestamp + 10);

        // deposit
        gasStart = gasleft();
        vm.prank(users[0]);
        IEToken(tokens[0]).mint(10 ether);
        uint256 gasUsedForDeposit = gasStart - gasleft();

        // start epoch 2
        vm.warp(gaugeManager.startTime() + 2 * 2 weeks);

        vm.prank(users[0]);
        gasStart = gasleft();
        gaugeManager.claim(_makeTokenArray(tokens[0]), users[0]);
        uint256 gasUsedForClaim = gasStart - gasleft();

        vm.prank(users[0]);
        gasStart = gasleft();
        IEToken(tokens[0]).redeem(10 ether, address(this));
        uint256 gasUsedForWithdraw = gasStart - gasleft();

        emit log_named_uint("Gas Used For Deposit", gasUsedForDeposit);
        emit log_named_uint("Gas Used For Claim", gasUsedForClaim);
        emit log_named_uint("Gas Used For Withdraw", gasUsedForWithdraw);
    }
}
