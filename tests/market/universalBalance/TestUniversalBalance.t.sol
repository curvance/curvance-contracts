// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IMToken, AccountSnapshot } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";

import { DToken } from "contracts/market/collateral/DToken.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
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

        // deploy dUSDC
        {
            _deployDUSDC();
            // support market
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(dUSDC), 200000e6);
            marketManager.listToken(address(dUSDC));
            // add MToken support on price router
            oracleRouter.addMTokenSupport(address(dUSDC));
            address[] memory markets = new address[](1);
            markets[0] = address(dUSDC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

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
            _prepareWBTC(owner, 1e8);
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

    function _prepareWBTC(address user, uint256 amount) internal {
        deal(address(WBTC), user, amount);
    }

    function testInitialize() public {
        assertEq(address(universalBalance.linkedDToken()), address(dWETH));
        assertEq(universalBalance.WETH(), _WETH_ADDRESS);
    }

    function testDepositETH() public {
        // provide fee to universal balance
        vm.deal(user1, 1 ether);
        vm.startPrank(user1);
        universalBalance.depositETH{ value: 1 ether }(false);
        vm.stopPrank();
    }
}
