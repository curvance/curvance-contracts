// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { GMAdaptor } from "contracts/oracles/adaptors/gmx/GMAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestGMAdaptor is TestBaseOracleManager {
    address internal _GMX_READER = 0xf60becbba223EEA9495Da3f606753867eC10d139;
    address internal _GMX_DATASTORE =
        0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address internal _GM_BTC_USDC = 0x47c031236e19d024b42f8AE6780E44A573170703;
    address internal _CHAINLINK_WBTC_USD =
        0xd0C7101eACbB49F3deCcCc166d238410D6D46d57;

    GMAdaptor public adaptor;

    function setUp() public override {
        _fork("ETH_NODE_URI_ARBITRUM", 145755190);

        
        _deployCentralRegistry();
        _deployOracleManager();

        adaptor = new GMAdaptor(
            ICentralRegistry(address(centralRegistry)),
            _GMX_READER,
            _GMX_DATASTORE
        );
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_WBTC_ADDRESS, _CHAINLINK_WBTC_USD, 0, true);
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, _CHAINLINK_USDC_USD, 0, true);

        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor.addAsset(_GM_BTC_USDC, _WBTC_ADDRESS);

        oracleManager.addAssetPriceFeed(_GM_BTC_USDC, address(adaptor));
    }

    function testDeploymentRevertWhenCentralRegistryIsInvalid() public {
        vm.expectRevert(
            BaseOracleAdaptor
                .BaseOracleAdaptor__InvalidCentralRegistry
                .selector
        );
        new GMAdaptor(
            ICentralRegistry(address(0)),
            _GMX_READER,
            _GMX_DATASTORE
        );
    }

    function testDeploymentRevertWhenReaderIsZeroAddress() public {
        vm.expectRevert(GMAdaptor.GMAdaptor__GMXReaderIsZeroAddress.selector);
        new GMAdaptor(
            ICentralRegistry(address(centralRegistry)),
            address(0),
            _GMX_DATASTORE
        );
    }

    function testDeploymentRevertWhenDataStoreIsZeroAddress() public {
        vm.expectRevert(
            GMAdaptor.GMAdaptor__GMXDataStoreIsZeroAddress.selector
        );
        new GMAdaptor(
            ICentralRegistry(address(centralRegistry)),
            _GMX_READER,
            address(0)
        );
    }

    function testAddAssetRevertWhenAlteredTokenIsInvalid() public {
        adaptor.removeAsset(_GM_BTC_USDC);

        vm.expectRevert(GMAdaptor.GMAdaptor__AlteredTokenIsInvalid.selector);
        adaptor.addAsset(_GM_BTC_USDC, address(0));
    }

    function testAddAssetRevertWhenLongTokenIsNotSupported() public {
        adaptor.removeAsset(_GM_BTC_USDC);
        oracleManager.removeAssetPriceFeed(
            _WBTC_ADDRESS,
            address(chainlinkAdaptor)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                GMAdaptor.GMAdaptor__MarketTokenIsNotSupported.selector,
                _WBTC_ADDRESS
            )
        );
        adaptor.addAsset(_GM_BTC_USDC, _WBTC_ADDRESS);
    }

    function testAddAssetRevertWhenShortTokenIsNotSupported() public {
        adaptor.removeAsset(_GM_BTC_USDC);
        oracleManager.removeAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                GMAdaptor.GMAdaptor__MarketTokenIsNotSupported.selector,
                _USDC_ADDRESS
            )
        );
        adaptor.addAsset(_GM_BTC_USDC, _WBTC_ADDRESS);
    }

    function testRemoveAssetRevertWhenGCTokenIsNotSupported() public {
        adaptor.removeAsset(_GM_BTC_USDC);

        vm.expectRevert(GMAdaptor.GMAdaptor__AssetIsNotSupported.selector);
        adaptor.removeAsset(_GM_BTC_USDC);
    }

    function testReturnsCorrectPriceInUSD() public {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _GM_BTC_USDC,
            true,
            false
        );

        assertEq(errorCode, 0);
        assertApproxEqAbs(price, 1.1215e18, 0.0001e18);
    }

    function testReturnsCorrectPriceInETH() public {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _GM_BTC_USDC,
            false,
            false
        );

        assertEq(errorCode, 0);
        assertApproxEqAbs(price, 0.000625e18, 0.000001e18);
    }

    function testRevertSetGMXReader__Unauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector
        );
        adaptor.setGMXReader(address(0));
    }

    function testRevertSetGMXDataStore__Unauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector
        );
        adaptor.setGMXDataStore(address(0));
    }
}
