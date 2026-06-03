// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    BaseOracleAdaptor
} from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import {
    PendlePrincipalTokenAdaptor
} from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";
import {
    ChainlinkAdaptor
} from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";

import {
    IPendlePTOracle
} from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import {IPMarket} from "contracts/interfaces/external/pendle/IPMarket.sol";
import {
    IChainlink
} from "contracts/interfaces/external/chainlink/IChainlink.sol";

import {TestBaseOracleManager} from "../TestBaseOracleManager.sol";

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
            PendlePrincipalTokenAdaptor.PendlePrincipalTokenAdaptor__QuoteAssetIsNotSupported
                .selector
        );
        adapter.addAsset(_PT_STETH, assetConfig);
    }

    function testReturnsCorrectPrice() public {
        _setUpPriceablePrincipalToken();

        (uint256 price, uint256 errorCode) = _getPtUsdQuote();
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testReturnsCorrectNativeDenominatedPrice() public {
        _setUpPriceablePrincipalToken();

        (uint256 price, uint256 errorCode) =
            oracleManager.getPrice(_PT_STETH, false, false);
        assertEq(errorCode, 0, "expected clean PT native price");
        assertGt(price, 0, "missing PT native price");
    }

    function testRuntimeQuoteAssetErrorBubblesHadError() public {
        _setUpPriceablePrincipalToken();

        vm.mockCall(
            _CHAINLINK_ETH_USD,
            abi.encodeWithSelector(IChainlink.latestRoundData.selector),
            abi.encode(
                uint80(1),
                int256(1e8),
                block.timestamp - 2 days,
                block.timestamp - 2 days,
                uint80(1)
            )
        );

        IOracleAdaptor.PricingResult memory adaptorResult =
            adapter.getPrice(_PT_STETH, true, false);
        assertTrue(
            adaptorResult.hadError,
            "expected PT adaptor to bubble quote asset error"
        );
        assertEq(
            adaptorResult.price,
            0,
            "expected PT adaptor price to zero on quote asset error"
        );

        (uint256 price, uint256 errorCode) = _getPtUsdQuote();
        assertEq(price, 0, "expected OracleManager PT price to zero");
        assertGt(errorCode, 0, "expected OracleManager PT error code");
    }

    function testRuntimePendleTwapErrorBubblesHadError() public {
        _setUpPriceablePrincipalToken();

        vm.mockCallRevert(_LP_STETH, abi.encodeWithSelector(IPMarket.observe.selector), "observe failed");

        IOracleAdaptor.PricingResult memory adaptorResult = adapter.getPrice(_PT_STETH, true, false);
        assertTrue(adaptorResult.hadError, "expected PT adaptor to convert Pendle TWAP failure into hadError");
        assertEq(adaptorResult.price, 0, "expected PT adaptor price to zero on Pendle TWAP failure");

        (uint256 price, uint256 errorCode) = _getPtUsdQuote();
        assertEq(price, 0, "expected OracleManager PT price to zero");
        assertGt(errorCode, 0, "expected OracleManager PT error code");
    }

    function testPriceGuard_finalPtUsdQuoteClampsThroughBaseAdjustPrice()
        public
    {
        _setUpPriceablePrincipalToken();

        (uint256 priceBefore, uint256 errorBefore) = _getPtUsdQuote();
        assertEq(errorBefore, 0, "expected clean PT USD price");
        assertGt(priceBefore, 0, "missing PT USD price");

        uint256 guardCap = priceBefore / 2;
        adapter.setGuardedPriceConfig(_PT_STETH, true, 0, 0, guardCap, 0);

        BaseOracleAdaptor.PriceGuard memory storedGuard =
            adapter.getPriceGuard(_PT_STETH, true);
        assertEq(
            storedGuard.basePrice,
            guardCap,
            "expected PT USD guard to be stored"
        );

        uint256 expectedPostFixQuote =
            _expectedStaticGuardedPrice(priceBefore, storedGuard);
        assertEq(
            expectedPostFixQuote,
            guardCap,
            "post-fix PT quote should clamp to stored guard cap"
        );

        (uint256 priceAfter, uint256 errorAfter) = _getPtUsdQuote();
        assertEq(errorAfter, 0, "expected clean PT USD price after guard");
        assertEq(
            priceAfter,
            expectedPostFixQuote,
            "expected final PT USD quote to clamp through BaseOracleAdaptor._adjustPrice"
        );
        assertEq(
            priceAfter,
            guardCap,
            "expected final PT USD quote to equal the stored guard cap"
        );
        assertLt(
            priceAfter,
            priceBefore,
            "expected final PT USD quote to clamp below the pre-guard quote"
        );
    }

    function testPriceGuard_finalPtUsdQuoteReturnsErrorWhenGuardMinExceedsComposedQuote()
        public
    {
        _setUpPriceablePrincipalToken();

        (uint256 ptPriceBefore, uint256 ptErrorBefore) = _getPtUsdQuote();
        assertEq(ptErrorBefore, 0, "expected clean PT USD price");
        assertGt(ptPriceBefore, 0, "missing PT USD price");

        // Pin the PT guard floor at the current quote so any composed drop
        // below it must trigger the `_adjustPrice == 0 -> hadError` bubble.
        adapter.setGuardedPriceConfig(
            _PT_STETH, true, 0, 0, ptPriceBefore, ptPriceBefore
        );

        // Halve stETH USD via a guard on the quote asset to drag the composed
        // PT quote below the PT min guard.
        (uint256 stethPriceBefore, uint256 stethErrorBefore) =
            oracleManager.getPrice(_STETH, true, false);
        assertEq(stethErrorBefore, 0, "expected clean stETH USD price");
        assertGt(stethPriceBefore, 0, "missing stETH USD price");

        chainlinkAdaptor.setGuardedPriceConfig(
            _STETH, true, 0, 0, stethPriceBefore / 2, 0
        );

        IOracleAdaptor.PricingResult memory adaptorResult =
            adapter.getPrice(_PT_STETH, true, false);
        assertTrue(
            adaptorResult.hadError,
            "expected PT adaptor call to signal an error"
        );
        assertTrue(
            adaptorResult.inUSD, "expected PT adaptor call to stay in usd mode"
        );
        assertEq(
            adaptorResult.price,
            0,
            "expected PT adaptor call to return zero after guard rejection"
        );

        (uint256 ptPriceAfter, uint256 ptErrorAfter) = _getPtUsdQuote();
        assertEq(
            ptPriceAfter,
            0,
            "expected oracle manager PT price to zero when adaptor errors"
        );
        assertGt(
            ptErrorAfter,
            0,
            "expected oracle manager to bubble PT adaptor error"
        );
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
            PendlePrincipalTokenAdaptor.PendlePrincipalTokenAdaptor__WrongMarket
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
            PendlePrincipalTokenAdaptor.PendlePrincipalTokenAdaptor__CallIncreaseCardinality
                .selector
        );
        adapter.addAsset(_PT_STETH, assetConfig);
    }

    function testRevertAddAsset__OldestObservationIsNotSatisfied() public {
        chainlinkAdaptor =
            new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(_STETH, true, _CHAINLINK_ETH_USD, 0);
        oracleManager.addAssetPricingAdaptor(
            _STETH, address(chainlinkAdaptor), 100, 50, 100, 50
        );

        vm.mockCall(
            _PT_ORACLE,
            abi.encodeWithSelector(IPendlePTOracle.getOracleState.selector),
            abi.encode(false, uint16(0), false)
        );

        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;

        vm.expectRevert(
            PendlePrincipalTokenAdaptor.PendlePrincipalTokenAdaptor__OldestObservationIsNotSatisfied
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
            PendlePrincipalTokenAdaptor.PendlePrincipalTokenAdaptor__TwapDurationIsLessThanMinimum
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
            PendlePrincipalTokenAdaptor.PendlePrincipalTokenAdaptor__WrongQuote
                .selector
        );
        adapter.addAsset(_PT_STETH, assetConfig);
    }

    function testCanUpdateAsset() public {
        // set quote asset
        chainlinkAdaptor =
            new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, true, _CHAINLINK_ETH_USD, 0);
        chainlinkAdaptor.addAsset(_STETH, true, _CHAINLINK_ETH_USD, 0);
        oracleManager.addAssetPricingAdaptor(
            _ETH_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50
        );
        oracleManager.addAssetPricingAdaptor(
            _STETH, address(chainlinkAdaptor), 100, 50, 100, 50
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

    function testRevertAddAsset__ZeroAddress() public {
        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;
        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector
        );
        adapter.addAsset(address(0), assetConfig);
    }

    function _setUpPriceablePrincipalToken() internal {
        chainlinkAdaptor =
            new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, true, _CHAINLINK_ETH_USD, 0);
        chainlinkAdaptor.addAsset(_STETH, true, _CHAINLINK_ETH_USD, 0);
        oracleManager.addAssetPricingAdaptor(
            _ETH_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50
        );
        oracleManager.addAssetPricingAdaptor(
            _STETH, address(chainlinkAdaptor), 100, 50, 100, 50
        );

        PendlePrincipalTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.market = IPMarket(_LP_STETH);
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.quoteAssetDecimals = 18;
        adapter.addAsset(_PT_STETH, assetConfig);

        oracleManager.addApprovedAdaptor(address(adapter));
        oracleManager.addAssetPricingAdaptor(
            _PT_STETH, address(adapter), 100, 50, 100, 50
        );
    }

    function _getPtUsdQuote()
        internal
        view
        returns (uint256 price, uint256 errorCode)
    {
        (price, errorCode) = oracleManager.getPrice(_PT_STETH, true, false);
    }

    function _expectedStaticGuardedPrice(
        uint256 rawPrice,
        BaseOracleAdaptor.PriceGuard memory guard
    ) internal pure returns (uint256) {
        if (guard.basePrice == 0) {
            return rawPrice;
        }
        if (rawPrice < guard.minPrice) {
            return 0;
        }
        return rawPrice > guard.basePrice ? guard.basePrice : rawPrice;
    }
}
