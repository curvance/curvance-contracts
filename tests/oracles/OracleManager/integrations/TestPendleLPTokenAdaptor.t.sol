// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract TestPendleLPTokenAdaptor is TestBaseOracleManager {
    address internal _PT_ORACLE = 0x14030836AEc15B2ad48bB097bd57032559339c92;
    address internal _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF; // PT-stETH-26DEC24
    address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2; // PT-stETH-26DEC24/SY-stETH Market

    PendleLPTokenAdaptor public adapter;

    function setUp() public override {
        _fork(18031848);

        _deployCentralRegistry();
        _deployOracleManager();

        adapter = new PendleLPTokenAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IPendlePTOracle(_PT_ORACLE)
        );
    }

    function testRevertWhenUnderlyingAssetPriceNotSet() public {
        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = _STETH;
        adapterData.pt = _PT_STETH;
        adapterData.quoteAssetDecimals = 18;
        vm.expectRevert(
            PendleLPTokenAdaptor
                .PendleLPTokenAdaptor__QuoteAssetIsNotSupported
                .selector
        );
        adapter.addAsset(_LP_STETH, adapterData);
    }

    function testReturnsCorrectPrice() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_STETH, _CHAINLINK_ETH_USD, 0, true);
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));

        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = _STETH;
        adapterData.pt = _PT_STETH;
        adapterData.quoteAssetDecimals = 18;
        adapter.addAsset(_LP_STETH, adapterData);

        oracleManager.addApprovedAdaptor(address(adapter));
        oracleManager.addAssetPriceFeed(_LP_STETH, address(adapter));

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _LP_STETH,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adapter.removeAsset(_LP_STETH);
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_LP_STETH, true, false);
    }

    function testRevertAddAsset__WrongMarket() public {
        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = _STETH;
        adapterData.pt = address(0);
        adapterData.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendleLPTokenAdaptor.PendleLPTokenAdaptor__WrongMarket.selector
        );
        adapter.addAsset(_LP_STETH, adapterData);
    }

    function testRevertAddAsset__CallIncreaseCardinality() public {
        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 1000;
        adapterData.quoteAsset = _STETH;
        adapterData.pt = _PT_STETH;
        adapterData.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendleLPTokenAdaptor
                .PendleLPTokenAdaptor__CallIncreaseCardinality
                .selector
        );
        adapter.addAsset(_LP_STETH, adapterData);
    }

    function testRevertAddAsset__TwapDurationIsLessThanMinimum() public {
        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 6;
        adapterData.quoteAsset = _STETH;
        adapterData.pt = _PT_STETH;
        adapterData.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendleLPTokenAdaptor
                .PendleLPTokenAdaptor__TwapDurationIsLessThanMinimum
                .selector
        );
        adapter.addAsset(_LP_STETH, adapterData);
    }

    function testRevertAddAsset__WrongQuote() public {
        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = address(0);
        adapterData.pt = _PT_STETH;
        adapterData.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendleLPTokenAdaptor.PendleLPTokenAdaptor__WrongQuote.selector
        );
        adapter.addAsset(_LP_STETH, adapterData);
    }

    function testCanUpdateAsset() public {
        // set quote asset
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_STETH, _CHAINLINK_ETH_USD, 0, true);
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));

        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = _STETH;
        adapterData.pt = _PT_STETH;
        adapterData.quoteAssetDecimals = 18;
        adapter.addAsset(_LP_STETH, adapterData);
        adapter.addAsset(_LP_STETH, adapterData);
    }

    function testRevertRemoveAsset__AssetIsNotSupported() public {
        vm.expectRevert(
            PendleLPTokenAdaptor
                .PendleLPTokenAdaptor__AssetIsNotSupported
                .selector
        );
        adapter.removeAsset(_LP_STETH);
    }
}
