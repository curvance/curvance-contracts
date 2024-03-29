// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { CurvanceAuxiliaryData } from "contracts/indexing/CurvanceAuxiliaryData.sol";
// import { MarketManager } from "contracts/market/MarketManager.sol";
// import "forge-std/console.sol";

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

    // function testAustin() public {
    //     ICentralRegistry cr = ICentralRegistry(address(centralRegistry));
    //     CurvanceAuxiliaryData aux = new CurvanceAuxiliaryData(cr);

    //     address firstMarket = centralRegistry.queryMarketManagers()[0];
    //     MarketManager mm = MarketManager(firstMarket);

    //     mm.listToken(address(dUSDC));
    //     mm.listToken(address(cBALRETH));

    //     // address[] memory assets = aux.getMarketAssets(address(mm));
    //     // console.log(aux.getTokenBorrows(assets[1]));
    //     console.log(aux.getMarketDebtAssets(address(mm)).length);
    // }
}
