// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";

import { EToken } from "contracts/market/token/EToken.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestUniversalBalanceNative is TestBaseMarket {
    address public owner;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;
    MockV3Aggregator public mockWbtcFeed;

    SimplePToken public cWBTC;
    UniversalBalanceNative public universalBalanceNative;
    EToken public eWETH;

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

        eWETH = _deployEToken(_WETH_ADDRESS);

        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        // start epoch
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWbtcFeed.updateAnswer(60000e8);

        // deploy eWETH
        {
            // support market
            _prepareWETH(owner, 200000 ether);
            weth.approve(address(eWETH), 200000e18);
            marketManager.listToken(address(eWETH));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eWETH));
            address[] memory markets = new address[](1);
            markets[0] = address(eWETH);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        // deploy cWBTC
        {
            // deploy aura position vault
            cWBTC = new SimplePToken(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManager)
            );

            // support market
            _prepareWBTC(owner, 1e8);
            wbtc.approve(address(cWBTC), 1e8);
            marketManager.listToken(address(cWBTC));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(cWBTC));
            // set position token configuration
            marketManager.updatePositionToken(
                address(cWBTC),
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
        assertEq(
            address(universalBalanceNative.linkedEToken()),
            address(eWETH)
        );
        assertEq(universalBalanceNative.underlying(), _WETH_ADDRESS);
    }

    function testDeposit() public {
        _prepareWETH(user1, 200e18);

        uint256 receiveAmount = eWETH.convertToShares(100e18);
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );

        vm.startPrank(user1);
        weth.approve(address(universalBalanceNative), 100e18);
        universalBalanceNative.deposit(100e18, false);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(weth.balanceOf(user1), 100e18);

        vm.startPrank(user1);
        weth.approve(address(universalBalanceNative), 100e18);
        universalBalanceNative.deposit(100e18, true);
        vm.stopPrank();

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
            user1
        );
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 100e18);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), 0);
    }

    function testDepositNative() public {
        vm.deal(user1, 200e18);

        uint256 receiveAmount = eWETH.convertToShares(100e18);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );

        vm.prank(user1);
        universalBalanceNative.depositNative{ value: 100e18 }(false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(user1.balance, 100e18);

        vm.prank(user1);
        universalBalanceNative.depositNative{ value: 100e18 }(true);

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
            user1
        );
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 100e18);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + receiveAmount
        );
        assertEq(user1.balance, 0);
    }

    function testWithdraw() public {
        testDeposit();

        uint256 redeemAmount = eWETH.convertToShares(100e18);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );

        vm.prank(user1);
        universalBalanceNative.withdraw(100e18, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 100e18);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(weth.balanceOf(user2), 100e18);

        vm.prank(user1);
        universalBalanceNative.withdraw(100e18, true, user2);

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
            user1
        );
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - redeemAmount
        );
        assertEq(weth.balanceOf(user2), 200e18);
    }

    function testWithdrawNative() public {
        testDepositNative();

        uint256 redeemAmount = eWETH.convertToShares(100e18);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);
        universalBalanceNative.withdrawNative(100e18, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 100e18);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(user2.balance, userETHBalance + 100e18);

        vm.prank(user1);
        universalBalanceNative.withdrawNative(100e18, true, user2);

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
            user1
        );
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - redeemAmount
        );
        assertEq(user2.balance, userETHBalance + 200e18);

        vm.stopPrank();
    }

    function testLentBalanceIncreased() public {
        testDeposit();

        // mint cWBTC & borrow WETH
        _prepareWBTC(user2, 100e8);
        vm.startPrank(user2);
        wbtc.approve(address(cWBTC), 100e8);
        cWBTC.mint(100e8, user2);
        marketManager.postCollateral(user2, address(cWBTC), 100e8);
        eWETH.borrow(50e18);

        vm.stopPrank();

        skip(10 weeks);

        _prepareWETH(owner, 100e18);
        weth.approve(address(eWETH), 100e18);
        eWETH.mint(100e18);

        vm.prank(user1);
        universalBalanceNative.withdrawNative(50e18, true, address(this));

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertGt(lentBalance, 50e18);
    }
}
