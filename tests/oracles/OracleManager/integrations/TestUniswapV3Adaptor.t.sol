// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { UniswapV3Adaptor } from "contracts/oracles/adaptors/uniswap/UniswapV3Adaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { IStaticOracle } from "contracts/interfaces/external/uniswap/IStaticOracle.sol";

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestUniswapV3Adaptor is TestBaseOracleManager {
    address internal _UNISWAP_V3_ORACLE =
        0xB210CE856631EeEB767eFa666EC7C1C57738d438;
    address internal _WBTC_WETH = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD;
    address internal _WBTC_USDC = 0x9a772018FbD77fcD2d25657e5C547BAfF3Fd7D16;

    UniswapV3Adaptor public adaptor;

    function setUp() public override {
        _fork(18031848);

        
        _deployCentralRegistry();
        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_WETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, _CHAINLINK_USDC_USD, 0, true);

        adaptor = new UniswapV3Adaptor(
            ICentralRegistry(address(centralRegistry)),
            IStaticOracle(_UNISWAP_V3_ORACLE),
            _WETH_ADDRESS
        );
        UniswapV3Adaptor.AssetConfig memory assetConfig;
        assetConfig.priceSource = _WBTC_WETH;
        assetConfig.secondsAgo = 3600;
        adaptor.addAsset(_WBTC_ADDRESS, assetConfig);

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adaptor));
    }

    function testRevertWhenUnderlyingChainAssetPriceNotSet() public {
        chainlinkAdaptor.removeAsset(_WETH_ADDRESS);

        (, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 2);
    }

    function testReturnsCorrectPriceInUSD() public {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testReturnsCorrectPriceInETH() public {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            false,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPriceInUSD();
        testReturnsCorrectPriceInETH();

        adaptor.removeAsset(_WBTC_ADDRESS);
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_WBTC_ADDRESS, true, false);
    }

    function testRevertGetPriceInETH__NotSupported() public {
        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector
        );
        adaptor.getPrice(address(0), false, false);
    }

    function testRevertAddAsset__SecondsAgoIsLessThanMinimum() public {
        UniswapV3Adaptor.AssetConfig memory assetConfig;
        assetConfig.priceSource = _WBTC_WETH;
        assetConfig.secondsAgo = 240;

        vm.expectRevert(
            UniswapV3Adaptor
                .UniswapV3Adaptor__SecondsAgoIsLessThanMinimum
                .selector
        );
        adaptor.addAsset(_WBTC_ADDRESS, assetConfig);
    }

    function testRevertAddAsset__AssetIsNotSupported() public {
        UniswapV3Adaptor.AssetConfig memory assetConfig;
        assetConfig.priceSource = _WBTC_WETH;
        assetConfig.secondsAgo = 3600;
        vm.expectRevert(
            UniswapV3Adaptor.UniswapV3Adaptor__AssetIsNotSupported.selector
        );
        adaptor.addAsset(_USDC_ADDRESS, assetConfig);
    }

    function testAddAssetForDifferentPair() public {
        testReturnsCorrectPriceInUSD();
        testReturnsCorrectPriceInETH();

        UniswapV3Adaptor.AssetConfig memory assetConfig;
        assetConfig.priceSource = _WBTC_USDC;
        assetConfig.secondsAgo = 3600;
        adaptor.addAsset(_WBTC_ADDRESS, assetConfig);
    }

    function testRevertRemoveAsset__AssetIsNotSupported() public {
        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector
        );
        adaptor.removeAsset(_USDC_ADDRESS);
    }

    function testGetPriceFromDifferentPair() public {
        UniswapV3Adaptor.AssetConfig memory assetConfig;
        assetConfig.priceSource = _WBTC_USDC;
        assetConfig.secondsAgo = 3600;
        adaptor.addAsset(_USDC_ADDRESS, assetConfig);

        IOracleAdaptor.PricingResult memory result = adaptor.getPrice(
            _USDC_ADDRESS,
            true,
            false
        );
        assertGt(result.price, 0);
        assertFalse(result.hadError);
        assertTrue(result.inUSD);

        result = adaptor.getPrice(_USDC_ADDRESS, false, false);
        assertGt(result.price, 0);
        assertFalse(result.hadError);
        assertFalse(result.inUSD);
    }

    function testRevertRemoveAsset__Unauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector
        );
        adaptor.removeAsset(_WBTC_ADDRESS);
    }
}
