// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

import { MockToken } from "contracts/mocks/MockToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CurvanceAuxiliaryData } from "contracts/indexing/CurvanceAuxiliaryData.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import "forge-std/console.sol";

contract TestBaseMarketManager is TestBaseMarket {
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    function setUp() public virtual override {
        super.setUp();

        gaugePool.start(address(marketManager));

        _prepareUSDC(address(this), _ONE);
        _prepareDAI(address(this), _ONE);
        _prepareBALRETH(address(this), _ONE);

        oracleRouter.addMTokenSupport(address(dDAI));

        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(dUSDC), _ONE);
        SafeTransferLib.safeApprove(_DAI_ADDRESS, address(dDAI), _ONE);
        SafeTransferLib.safeApprove(
            _BALANCER_WETH_RETH,
            address(cBALRETH),
            _ONE
        );

        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );
    }

    function testAustin() public {
        ICentralRegistry cr = ICentralRegistry(address(centralRegistry));
        CurvanceAuxiliaryData aux = new CurvanceAuxiliaryData(cr);

        address firstMarket = centralRegistry.queryMarketManagers()[0];
        MarketManager mm = MarketManager(firstMarket);

        mm.listToken(address(dUSDC));
        mm.listToken(address(cBALRETH));

        mm.updateCollateralToken(
            IMToken(address(cBALRETH)),
            7000,
            4000,
            3000,
            200,
            400,
            0,
            1000
        );
        address[] memory newCapTokens = new address[](1);
        uint256[] memory newCapValues = new uint256[](1);
        newCapTokens[0] = address(cBALRETH);
        newCapValues[0] = 1e25;
        mm.setCTokenCollateralCaps(newCapTokens, newCapValues);

        IERC20 usdc = IERC20(dUSDC.underlying());
        IERC20 balreth = IERC20(cBALRETH.underlying());

        balreth.approve(address(cBALRETH), 200);
        cBALRETH.depositAsCollateral(100, address(this));
        cBALRETH.mint(100, address(this));

        usdc.approve(address(dUSDC), 100e6);
        dUSDC.mint(100e6);

        console.log(
            "Single cToken Price: ",
            aux.getTokenPrice(address(cBALRETH))
        );
        console.log(
            "Total Collateral Posted in USD:",
            aux.getMarketCollateralPostedByUsd(firstMarket)
        );
        console.log(
            "Total Collateral Deposited in USD:",
            aux.getMarketCollateralTVL(firstMarket)
        );

        CurvanceAuxiliaryData.MarketData memory marketData = aux.getMarketData(
            firstMarket,
            address(this)
        );

        console.log("--- Market Data Start ---");
        console.log(marketData.totalTVL);
        console.log(marketData.collateralTVL);
        console.log(marketData.lendingTVL);
        console.log(marketData.borrows);
        console.log(marketData.collateralPostedByUsd);
        console.log(marketData.userMarketPosition.debt);
        console.log(marketData.userMarketPosition.collateral);
        console.log(marketData.userMarketPosition.maxDebt);

        (
            CurvanceAuxiliaryData.MarketDTokenData[] memory dTokenData,
            CurvanceAuxiliaryData.MarketCTokenData[] memory cTokenData
        ) = aux.getMarketAssetData(firstMarket, address(this));

        console.log("--- Market DToken Data Start ---");
        console.log(dTokenData[0].assetAddress);
        console.log(dTokenData[0].marketAddress);
        console.log(dTokenData[0].tvl);
        console.log("--- Market CToken Data Start ---");
        console.log(cTokenData[0].totalCollateralPosted);

        CurvanceAuxiliaryData.AllMarketData[] memory allMarketData = aux
            .getAllMarketData(address(this));
        console.log("--- All Market Data Start ---");
        console.log(allMarketData[0].marketData.totalTVL);
    }
}
