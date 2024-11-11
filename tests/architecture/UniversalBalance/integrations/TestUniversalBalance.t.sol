// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";

import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestUniversalBalance is TestBaseMarket {
    address public owner;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockStethFeed;
    MockV3Aggregator public mockWbtcFeed;

    SimplePToken public cWBTC;
    UniversalBalance public universalBalance;

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

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC)
        );

        // start epoch
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWbtcFeed.updateAnswer(60000e8);

        // deploy eUSDC
        {
            // support market
            deal(_USDC_ADDRESS, owner, 200_000e6);
            usdc.approve(address(eUSDC), 200_000e6);
            marketManager.listToken(address(eUSDC));

            address[] memory markets = new address[](1);
            markets[0] = address(eUSDC);
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
        assertEq(address(universalBalance.linkedEToken()), address(eUSDC));
        assertEq(universalBalance.underlying(), _USDC_ADDRESS);
    }

    function testDeposit() public {
        deal(_USDC_ADDRESS, user1, 200e6);

        uint256 receiveAmount = eUSDC.convertToShares(100e6);
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));

        vm.startPrank(user1);
        usdc.approve(address(universalBalance), 100e6);
        universalBalance.deposit(100e6, false);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e6);
        assertEq(lentBalance, 0);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance + 100e6
        );
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
        assertEq(usdc.balanceOf(user1), 100e6);

        vm.startPrank(user1);
        usdc.approve(address(universalBalance), 100e6);
        universalBalance.deposit(100e6, true);
        vm.stopPrank();

        (sittingBalance, lentBalance) = universalBalance.userBalances(user1);
        assertEq(sittingBalance, 100e6);
        assertEq(lentBalance, receiveAmount);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance + 100e6
        );
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance + receiveAmount
        );
        assertEq(usdc.balanceOf(user1), 0);
    }

    function testWithdraw() public {
        testDeposit();

        uint256 redeemAmount = eUSDC.convertToShares(100e6);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));

        vm.prank(user1);
        universalBalance.withdraw(100e6, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 100e6);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance - 100e6
        );
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
        assertEq(usdc.balanceOf(user2), 100e6);

        vm.prank(user1);
        universalBalance.withdraw(100e6, true, user2);

        (sittingBalance, lentBalance) = universalBalance.userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance - 100e6
        );
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance - redeemAmount
        );
        assertEq(usdc.balanceOf(user2), 200e6);
    }

    function testLentBalanceIncreased() public {
        testDeposit();

        // mint cWBTC & borrow USDC
        deal(_WBTC_ADDRESS, user2, 100e8);
        vm.startPrank(user2);
        wbtc.approve(address(cWBTC), 100e8);
        cWBTC.mint(100e8, user2);
        marketManager.postCollateral(user2, address(cWBTC), 100e8);
        eUSDC.borrow(50e6);

        vm.stopPrank();

        skip(10 weeks);

        deal(_USDC_ADDRESS, owner, 100e6);
        usdc.approve(address(eUSDC), 100e6);
        eUSDC.mint(100e6);

        vm.prank(user1);
        universalBalance.withdraw(50e6, true, address(this));

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e6);
        assertGt(lentBalance, 50e6);
    }
}
