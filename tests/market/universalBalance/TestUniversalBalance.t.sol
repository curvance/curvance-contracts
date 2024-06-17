// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";

import { DToken } from "contracts/market/collateral/DToken.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { CTokenPrimitive, IERC20 } from "contracts/market/collateral/CTokenPrimitive.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestUniversalBalance is TestBaseMarket {
    address public owner;

    receive() external payable {}

    fallback() external payable {}

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;
    MockV3Aggregator public mockWbtcFeed;

    CTokenPrimitive cWBTC;
    UniversalBalance universalBalance;

    IERC20 private WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 private WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    DToken dWETH;

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
        oracleRouter.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(dualChainlinkAdaptor)
        );

        dWETH = _deployDToken(_WETH_ADDRESS);

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(dWETH),
            _WETH_ADDRESS
        );

        // start epoch
        gaugePool.start(address(marketManager));
        vm.warp(gaugePool.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWbtcFeed.updateAnswer(60000e8);

        // deploy dWETH
        {
            // support market
            deal(_WETH_ADDRESS, owner, 200000 ether);
            WETH.approve(address(dWETH), 200000e6);
            marketManager.listToken(address(dWETH));
            // add MToken support on price router
            oracleRouter.addMTokenSupport(address(dWETH));
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
            cWBTC = new CTokenPrimitive(
                ICentralRegistry(address(centralRegistry)),
                WBTC,
                address(marketManager)
            );

            // support market
            deal(_WBTC_ADDRESS, owner, 1e8);
            WBTC.approve(address(cWBTC), 1e8);
            marketManager.listToken(address(cWBTC));
            // add MToken support on price router
            oracleRouter.addMTokenSupport(address(cWBTC));
            // set collateral token configuration
            marketManager.updateCollateralToken(
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
            marketManager.setCTokenCollateralCaps(mTokens, caps);

            // address[] memory markets = new address[](1);
            // markets[0] = address(cWBTC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }
    }

    function testInitialize() public {
        assertEq(address(universalBalance.linkedDToken()), address(dWETH));
        assertEq(universalBalance.WETH(), _WETH_ADDRESS);
    }

    function testDepositETH() public {
        vm.deal(user1, 1 ether);
        vm.startPrank(user1);
        universalBalance.depositETH{ value: 1 ether }(false);
        vm.stopPrank();

        vm.deal(user1, 1 ether);
        vm.startPrank(user1);
        universalBalance.depositETH{ value: 1 ether }(true);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 1 ether);
        assertEq(lentBalance, 1 ether);
    }

    function testDepositWETH() public {
        deal(_WETH_ADDRESS, user1, 1 ether);
        vm.startPrank(user1);
        weth.approve(address(universalBalance), 1 ether);
        universalBalance.depositWETH(1 ether, false);
        vm.stopPrank();

        deal(_WETH_ADDRESS, user1, 1 ether);
        vm.startPrank(user1);
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
        vm.stopPrank();

        vm.startPrank(user1);
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
        universalBalance.withdrawAsWETH(1 ether, false);
        vm.stopPrank();

        vm.startPrank(user1);
        universalBalance.withdrawAsWETH(1 ether, true);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
    }

    function testClaimForDAO() public {
        testDepositETH();

        vm.warp(gaugePool.startTime());
        vm.roll(block.number + 1000);

        // set gauge weights
        address[] memory tokensParam = new address[](1);
        tokensParam[0] = address(dWETH);
        uint256[] memory poolWeights = new uint256[](1);
        poolWeights[0] = 100 * 2 weeks;
        vm.prank(address(protocolMessagingHub));
        gaugePool.setEmissionRates(1, tokensParam, poolWeights);
        vm.prank(address(protocolMessagingHub));
        cve.mintGaugeEmissions(address(gaugePool), 100 * 2 weeks);

        vm.warp(gaugePool.startTime() + 1 * 2 weeks);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);

        skip(1 weeks);

        uint256 balanceBefore = cve.balanceOf(address(this));
        universalBalance.claimForDAO();
        assertEq(cve.balanceOf(address(this)), balanceBefore + 100 * 1 weeks);
    }

    function testLentBalanceIncreased() public {
        testDepositETH();

        // mint cWBTC & borrow WETH
        deal(_WBTC_ADDRESS, user2, 1e8);
        vm.startPrank(user2);
        WBTC.approve(address(cWBTC), 1e8);
        cWBTC.mint(1e8, user2);
        marketManager.postCollateral(user2, address(cWBTC), 1e8);
        dWETH.borrow(0.5 ether);

        vm.stopPrank();

        skip(10 weeks);

        vm.startPrank(user1);
        universalBalance.withdrawAsWETH(0.5 ether, true);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 1 ether);
        assertGt(lentBalance, 0.5 ether);
    }
}
