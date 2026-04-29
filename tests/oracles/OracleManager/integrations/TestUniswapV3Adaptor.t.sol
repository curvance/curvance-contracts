// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

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
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            _CHAINLINK_USDC_USD,
            0
        );

        adaptor = new UniswapV3Adaptor(
            ICentralRegistry(address(centralRegistry)),
            IStaticOracle(_UNISWAP_V3_ORACLE),
            _WETH_ADDRESS
        );
        oracleManager.addApprovedAdaptor(address(adaptor));
        
        UniswapV3Adaptor.AssetConfig memory assetConfig;
        assetConfig.priceSource = _WBTC_WETH;
        assetConfig.secondsAgo = 3600;
        adaptor.addAsset(_WBTC_ADDRESS, assetConfig);

        oracleManager.addAssetPricingAdaptor(
            _ETH_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            _WETH_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            _WBTC_ADDRESS, 
            address(adaptor), 
            100, 
            50,
            100,
            50
            );
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

    function testReturnsCorrectPriceInUSD() public view {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testReturnsCorrectPriceInETH() public view {
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

    function testRevertAddAsset__ZeroAddress() public {
        UniswapV3Adaptor.AssetConfig memory assetConfig;
        assetConfig.priceSource = _WBTC_WETH;
        assetConfig.secondsAgo = 3600;
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        adaptor.addAsset(address(0), assetConfig);
    }

    function testPriceGuard_finalUsdQuoteClampsThroughBaseAdjustPrice()
        public
    {
        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorBefore, 0, "expected clean WBTC USD price");
        assertGt(priceBefore, 0, "missing WBTC USD price");

        uint256 guardCap = priceBefore / 2;
        adaptor.setGuardedPriceConfig(_WBTC_ADDRESS, true, 0, 0, guardCap, 0);

        BaseOracleAdaptor.PriceGuard memory storedGuard = adaptor
            .getPriceGuard(_WBTC_ADDRESS, true);
        assertEq(
            storedGuard.basePrice,
            guardCap,
            "expected WBTC USD guard to be stored"
        );

        uint256 expectedPostFixQuote = _expectedStaticGuardedPrice(
            priceBefore,
            storedGuard
        );
        assertEq(
            expectedPostFixQuote,
            guardCap,
            "post-fix WBTC quote should clamp to stored guard cap"
        );

        (uint256 priceAfter, uint256 errorAfter) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorAfter, 0, "expected clean WBTC USD price after guard");
        assertEq(
            priceAfter,
            expectedPostFixQuote,
            "expected final WBTC USD quote to clamp through BaseOracleAdaptor._adjustPrice"
        );
        assertEq(
            priceAfter,
            guardCap,
            "expected final WBTC USD quote to equal the stored guard cap"
        );
        assertLt(
            priceAfter,
            priceBefore,
            "expected final WBTC USD quote to clamp below the pre-guard quote"
        );
    }

    function testPriceGuard_finalNativeQuoteClampsThroughBaseAdjustPrice()
        public
    {
        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            false,
            false
        );
        assertEq(errorBefore, 0, "expected clean WBTC native price");
        assertGt(priceBefore, 0, "missing WBTC native price");

        uint256 guardCap = priceBefore / 2;
        adaptor.setGuardedPriceConfig(_WBTC_ADDRESS, false, 0, 0, guardCap, 0);

        BaseOracleAdaptor.PriceGuard memory storedGuard = adaptor
            .getPriceGuard(_WBTC_ADDRESS, false);
        assertEq(
            storedGuard.basePrice,
            guardCap,
            "expected WBTC native guard to be stored"
        );

        uint256 expectedPostFixQuote = _expectedStaticGuardedPrice(
            priceBefore,
            storedGuard
        );
        assertEq(
            expectedPostFixQuote,
            guardCap,
            "post-fix WBTC native quote should clamp to stored guard cap"
        );

        (uint256 priceAfter, uint256 errorAfter) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            false,
            false
        );
        assertEq(
            errorAfter,
            0,
            "expected clean WBTC native price after guard"
        );
        assertEq(
            priceAfter,
            expectedPostFixQuote,
            "expected final WBTC native quote to clamp through BaseOracleAdaptor._adjustPrice"
        );
        assertEq(
            priceAfter,
            guardCap,
            "expected final WBTC native quote to equal the stored guard cap"
        );
        assertLt(
            priceAfter,
            priceBefore,
            "expected final WBTC native quote to clamp below the pre-guard quote"
        );
    }

    function testPriceGuard_finalUsdQuoteReturnsErrorWhenGuardMinExceedsComposedQuote()
        public
    {
        (uint256 wbtcPriceBefore, uint256 wbtcErrorBefore) = oracleManager
            .getPrice(_WBTC_ADDRESS, true, false);
        assertEq(wbtcErrorBefore, 0, "expected clean WBTC USD price");
        assertGt(wbtcPriceBefore, 0, "missing WBTC USD price");

        // Pin WBTC USD guard floor at the current quote so any composed drop
        // below it must trigger the `_adjustPrice == 0 -> hadError` bubble.
        adaptor.setGuardedPriceConfig(
            _WBTC_ADDRESS,
            true,
            0,
            0,
            wbtcPriceBefore,
            wbtcPriceBefore
        );

        // Halve WETH USD via a guard on the quote token to drag the composed
        // WBTC quote below the WBTC min guard. WBTC's USD route prices via
        // WBTC/WETH twap then the OracleManager WETH USD price.
        (uint256 wethPriceBefore, uint256 wethErrorBefore) = oracleManager
            .getPrice(_WETH_ADDRESS, true, false);
        assertEq(wethErrorBefore, 0, "expected clean WETH USD price");
        assertGt(wethPriceBefore, 0, "missing WETH USD price");

        chainlinkAdaptor.setGuardedPriceConfig(
            _WETH_ADDRESS,
            true,
            0,
            0,
            wethPriceBefore / 2,
            0
        );

        IOracleAdaptor.PricingResult memory adaptorResult = adaptor.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertTrue(
            adaptorResult.hadError,
            "expected WBTC adaptor call to signal an error"
        );
        assertTrue(
            adaptorResult.inUSD,
            "expected WBTC adaptor call to stay in usd mode"
        );
        assertEq(
            adaptorResult.price,
            0,
            "expected WBTC adaptor call to return zero after guard rejection"
        );

        (uint256 wbtcPriceAfter, uint256 wbtcErrorAfter) = oracleManager
            .getPrice(_WBTC_ADDRESS, true, false);
        assertEq(
            wbtcPriceAfter,
            0,
            "expected oracle manager WBTC price to zero when adaptor errors"
        );
        assertGt(
            wbtcErrorAfter,
            0,
            "expected oracle manager to bubble WBTC adaptor error"
        );
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
