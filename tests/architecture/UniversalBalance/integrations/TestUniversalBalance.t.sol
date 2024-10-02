// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";

import { EToken } from "contracts/market/token/EToken.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { PTokenPrimitive } from "contracts/market/token/PTokenPrimitive.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestUniversalBalance is TestBaseMarket {
    address public owner;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;
    MockV3Aggregator public mockWbtcFeed;

    PTokenPrimitive public cWBTC;
    UniversalBalance public universalBalance;
    EToken public dWETH;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );

        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );

        mockWbtcFeed = new MockV3Aggregator(8, 60000e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _WBTC_ADDRESS,
            address(mockWbtcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WBTC_ADDRESS,
            address(mockWbtcFeed),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(dualChainlinkAdaptor)
        );

        dWETH = _deployEToken(_WETH_ADDRESS);

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(dWETH),
            _WETH_ADDRESS
        );

        // start epoch
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWbtcFeed.updateAnswer(60000e8);

        // deploy dWETH
        {
            // support market
            deal(_WETH_ADDRESS, owner, 200000 ether);
            weth.approve(address(dWETH), 200000e18);
            marketManager.listToken(address(dWETH));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(dWETH));
            address[] memory markets = new address[](1);
            markets[0] = address(dWETH);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        // deploy cWBTC
        {
            // deploy aura position vault
            cWBTC = new PTokenPrimitive(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManager)
            );

            // support market
            deal(_WBTC_ADDRESS, owner, 1e8);
            wbtc.approve(address(cWBTC), 1e8);
            marketManager.listToken(address(cWBTC));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(cWBTC));
            // set position token configuration
            marketManager.updatePositionToken(
                IMToken(address(cWBTC)),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                0,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(cWBTC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100e8;
            marketManager.setPTokenCollateralCaps(mTokens, caps);

            // address[] memory markets = new address[](1);
            // markets[0] = address(cWBTC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }
    }

    function testInitialize() public {
        assertEq(address(universalBalance.linkedEToken()), address(dWETH));
        assertEq(universalBalance.WETH(), _WETH_ADDRESS);
    }

    function testDepositETH() public {
        vm.deal(user1, 100e18);
        vm.startPrank(user1);
        universalBalance.depositETH{ value: 100e18 }(false);

        vm.deal(user1, 100e18);
        universalBalance.depositETH{ value: 100e18 }(true);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 100e18);
    }

    function testDepositWETH() public {
        deal(_WETH_ADDRESS, user1, 1 ether);
        vm.startPrank(user1);
        weth.approve(address(universalBalance), 1 ether);
        universalBalance.depositWETH(1 ether, false);

        deal(_WETH_ADDRESS, user1, 1 ether);
        weth.approve(address(universalBalance), 1 ether);
        universalBalance.depositWETH(1 ether, true);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 1 ether);
        assertEq(lentBalance, 1 ether);
    }

    function testWithdrawAsETH() public {
        testDepositWETH();

        uint256 ethBalance = user1.balance;

        vm.startPrank(user1);
        universalBalance.withdrawAsETH(1 ether, false);

        assertEq(user1.balance, ethBalance + 1 ether);
        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 1 ether);

        universalBalance.withdrawAsETH(1 ether, true);

        assertEq(user1.balance, ethBalance + 2 ether);
        (sittingBalance, lentBalance) = universalBalance.userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0 ether);
        vm.stopPrank();
    }

    function testWithdrawAsWETH() public {
        testDepositETH();

        vm.startPrank(user1);
        universalBalance.withdrawAsWETH(100e18, false);

        universalBalance.withdrawAsWETH(100e18, true);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
    }

    function testClaimForDAO() public {
        testDepositETH();

        vm.warp(gaugeManager.startTime());
        _skipEpochDuration(1);

        vm.roll(block.number + 1000);

        // set gauge weights
        address[] memory tokensParam = new address[](1);
        tokensParam[0] = address(dWETH);
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 100 * 2 weeks;
        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(messagingHub));
        cve.mintGaugeEmissions(address(gaugeManager), 100 * 2 weeks);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);

        skip(1 weeks);

        uint256 balanceBefore = cve.balanceOf(address(this));
        universalBalance.claimForDAO();
        assertEq(cve.balanceOf(address(this)), balanceBefore + 100 * 1 weeks - 1);
    }

    function testLentBalanceIncreased() public {
        testDepositETH();

        // mint cWBTC & borrow WETH
        deal(_WBTC_ADDRESS, user2, 100e8);
        vm.startPrank(user2);
        wbtc.approve(address(cWBTC), 100e8);
        cWBTC.mint(100e8, user2);
        marketManager.postCollateral(user2, address(cWBTC), 100e8);
        dWETH.borrow(50e18);

        vm.stopPrank();

        skip(10 weeks);

        deal(_WETH_ADDRESS, owner, 100e18);
        weth.approve(address(dWETH), 100e18);
        dWETH.mint(100e18);

        vm.prank(user1);
        universalBalance.withdrawAsWETH(50e18, true);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertGt(lentBalance, 50e18);
    }
}
