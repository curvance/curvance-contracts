// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { PendlePrincipalTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestPendlePTTokenAdaptor is TestBaseOracleManager {
    address internal _PT_ORACLE = 0x14030836AEc15B2ad48bB097bd57032559339c92;
    
    address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF; // PT-stETH-26DEC24
    address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2; // PT-stETH-26DEC24/SY-stETH Market

    PendlePrincipalTokenAdaptor public adapter;

    function setUp() public override {
        _fork(18031848);

        _deployCentralRegistry();
        _deployOracleManager();

        adapter = new PendlePrincipalTokenAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IPendlePTOracle(_PT_ORACLE)
        );
    }

    function testRevertWhenUnderlyingAssetPriceNotSet() public {
        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;
        vm.expectRevert(
            PendlePrincipalTokenAdaptor
                .PendlePrincipalTokenAdaptor__QuoteAssetIsNotSupported
                .selector
        );
        adapter.addAsset(_PT_STETH, assetConfig);
    }

    function testReturnsCorrectPrice() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _STETH,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        oracleManager.addAssetPricingAdaptor(
            _ETH_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            _STETH, 
            address(chainlinkAdaptor),
            100, 
            50,
            100,
            50
            );

        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;
        adapter.addAsset(_PT_STETH, assetConfig);

        oracleManager.addApprovedAdaptor(address(adapter));
        oracleManager.addAssetPricingAdaptor(
            _PT_STETH, 
            address(adapter), 
            100, 
            50,
            100,
            50
            );

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _PT_STETH,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adapter.removeAsset(_PT_STETH);
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_PT_STETH, true, false);
    }

    function testRevertAddAsset__WrongMarket() public {
        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendlePrincipalTokenAdaptor
                .PendlePrincipalTokenAdaptor__WrongMarket
                .selector
        );
        adapter.addAsset(_STETH, assetConfig);
    }

    function testRevertAddAsset__CallIncreaseCardinality() public {
        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 1000;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendlePrincipalTokenAdaptor
                .PendlePrincipalTokenAdaptor__CallIncreaseCardinality
                .selector
        );
        adapter.addAsset(_PT_STETH, assetConfig);
    }

    function testRevertAddAsset__TwapDurationIsLessThanMinimum() public {
        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 6;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendlePrincipalTokenAdaptor
                .PendlePrincipalTokenAdaptor__TwapDurationIsLessThanMinimum
                .selector
        );
        adapter.addAsset(_PT_STETH, assetConfig);
    }

    function testRevertAddAsset__WrongQuote() public {
        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = address(0);
        assetConfig.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendlePrincipalTokenAdaptor
                .PendlePrincipalTokenAdaptor__WrongQuote
                .selector
        );
        adapter.addAsset(_PT_STETH, assetConfig);
    }

    function testCanUpdateAsset() public {
        // set quote asset
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _STETH,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        oracleManager.addAssetPricingAdaptor(
            _ETH_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            _STETH, 
            address(chainlinkAdaptor), 
            100, 
            50,
            100,
            50
            );

        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;
        adapter.addAsset(_PT_STETH, assetConfig);
        adapter.addAsset(_PT_STETH, assetConfig);
    }

    function testRevertRemoveAsset__AssetIsNotSupported() public {
        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector
        );
        adapter.removeAsset(_PT_STETH);
    }
}
