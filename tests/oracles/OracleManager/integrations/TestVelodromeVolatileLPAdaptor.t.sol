// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { BaseVolatileLPAdaptor } from "contracts/oracles/adaptors/stableswapBase/BaseVolatileLPAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestVelodromeVolatileLPAdaptor is TestBaseOracleManager {
    address internal _VELO_ROUTER = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address internal _VELODROME_WETH_USDC =
        0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;

    VelodromeVolatileLPAdaptor public adaptor;

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 110333246);

        _deployCentralRegistry();
        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor = new VelodromeVolatileLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        adaptor.addAsset(_VELODROME_WETH_USDC);

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
            _VELODROME_WETH_USDC,
            address(adaptor),
            100,
            50,
            100,
            50
        );
    }

    function _getVolatileLPUsdQuote()
        internal
        view
        returns (uint256 price, uint256 errorCode)
    {
        (price, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
    }

    function _storeUsdGuardAtHalfCurrentQuote()
        internal
        returns (
            uint256 priceBefore,
            uint256 guardCap,
            BaseOracleAdaptor.PriceGuard memory storedGuard
        )
    {
        uint256 errorBefore;
        (priceBefore, errorBefore) = _getVolatileLPUsdQuote();
        assertEq(errorBefore, 0, "tc010:expected-clean-usd-price");
        assertGt(priceBefore, 0, "tc010:missing-volatile-lp-price");

        guardCap = priceBefore / 2;
        adaptor.setGuardedPriceConfig(
            _VELODROME_WETH_USDC,
            true,
            0,
            0,
            guardCap,
            0
        );

        storedGuard = adaptor.getPriceGuard(_VELODROME_WETH_USDC, true);
    }

    // Mirrors the static clamp path that should apply once LP pricing flows
    // through BaseOracleAdaptor guard adjustment.
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

    function testRevertWhenUnderlyingChainAssetPriceNotSet() public {
        chainlinkAdaptor.removeAsset(_WETH_ADDRESS);

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_VELODROME_WETH_USDC, true, false);
    }

    function testReturnsCorrectPrice() public view {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adaptor.removeAsset(_VELODROME_WETH_USDC);
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_VELODROME_WETH_USDC, true, false);
    }

    function testRevertAddAsset__AssetIsNotVolatileLP() public {
        vm.expectRevert(
            BaseVolatileLPAdaptor.BaseVolatileLPAdaptor__InvalidAssetType
                .selector
        );
        adaptor.addAsset(0x19715771E30c93915A5bbDa134d782b81A820076);
    }

    function testCanUpdateAsset() public {
        adaptor.addAsset(_VELODROME_WETH_USDC);
        adaptor.addAsset(_VELODROME_WETH_USDC);
    }

    function testPriceDoesNotChangeAfterLargeSwap() public {
        uint256 errorCode;
        uint256 priceBefore;
        (priceBefore, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(priceBefore, 0);

        // try large swap (500K _USDC_ADDRESS)
        uint256 amount = 500000e6;
        _prepareUSDC(address(this), amount);
        VelodromeLib._swapExactTokensForTokens(
            _VELO_ROUTER,
            _VELODROME_WETH_USDC,
            _USDC_ADDRESS,
            _WETH_ADDRESS,
            amount,
            false
        );

        assertEq(usdc.balanceOf(address(this)), 0);
        assertGt(weth.balanceOf(address(this)), 0);

        uint256 priceAfter;
        (priceAfter, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertApproxEqRel(priceBefore, priceAfter, 100000);
    }

    function testPriceDoesNotChangeAfterTenTimesLargeSwap() public {
        uint256 errorCode;
        uint256 priceBefore;
        (priceBefore, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(priceBefore, 0);

        // try large swap (5M _USDC_ADDRESS)
        uint256 amount = 5000000e6;
        _prepareUSDC(address(this), amount);
        VelodromeLib._swapExactTokensForTokens(
            _VELO_ROUTER,
            _VELODROME_WETH_USDC,
            _USDC_ADDRESS,
            _WETH_ADDRESS,
            amount,
            false
        );

        assertEq(usdc.balanceOf(address(this)), 0);
        assertGt(weth.balanceOf(address(this)), 0);

        uint256 priceAfter;
        (priceAfter, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertApproxEqRel(priceBefore, priceAfter, 100000);
    }

    function testPriceGuard_underlyingOracleManagerPricingBindsAndFinalLPQuoteClampsThroughAdjustPrice()
        public
    {
        (uint256 lpPriceBefore, uint256 lpErrorBefore) = _getVolatileLPUsdQuote();
        assertEq(lpErrorBefore, 0, "tc010:expected-clean-lp-usd-price");
        assertGt(lpPriceBefore, 0, "tc010:missing-volatile-lp-price");

        (uint256 wethPriceBefore, uint256 wethErrorBefore) = oracleManager
            .getPrice(_WETH_ADDRESS, true, false);
        assertEq(
            wethErrorBefore,
            0,
            "tc010:expected-clean-underlying-weth-usd-price"
        );
        assertGt(wethPriceBefore, 0, "tc010:missing-underlying-weth-price");

        uint256 wethGuardCap = wethPriceBefore / 2;
        chainlinkAdaptor.setGuardedPriceConfig(
            _WETH_ADDRESS,
            true,
            0,
            0,
            wethGuardCap,
            0
        );

        BaseOracleAdaptor.PriceGuard memory storedWethGuard = chainlinkAdaptor
            .getPriceGuard(_WETH_ADDRESS, true);
        assertEq(
            storedWethGuard.basePrice,
            wethGuardCap,
            "tc010:expected-underlying-weth-usd-guard-to-be-stored"
        );

        (uint256 wethPriceAfter, uint256 wethErrorAfter) = oracleManager
            .getPrice(_WETH_ADDRESS, true, false);
        assertEq(
            wethErrorAfter,
            0,
            "tc010:expected-clean-underlying-weth-usd-price-after-guard"
        );
        assertEq(
            wethPriceAfter,
            _expectedStaticGuardedPrice(wethPriceBefore, storedWethGuard),
            "tc010:expected-underlying-weth-pricing-to-still-bind-through-oracle-manager"
        );

        (
            uint256 lpPriceAfterUnderlyingGuard,
            uint256 lpErrorAfterUnderlyingGuard
        ) = _getVolatileLPUsdQuote();
        assertEq(
            lpErrorAfterUnderlyingGuard,
            0,
            "tc010:expected-clean-lp-usd-price-after-underlying-guard"
        );
        assertLt(
            lpPriceAfterUnderlyingGuard,
            lpPriceBefore,
            "tc010:expected-underlying-oracle-manager-pricing-to-flow-through-lp-quote"
        );

        (
            uint256 lpPriceBeforeLpGuard,
            uint256 lpGuardCap,
            BaseOracleAdaptor.PriceGuard memory storedLpGuard
        ) = _storeUsdGuardAtHalfCurrentQuote();
        uint256 expectedLpPriceIfAdjusted =
            _expectedStaticGuardedPrice(lpPriceBeforeLpGuard, storedLpGuard);

        assertEq(
            lpPriceBeforeLpGuard,
            lpPriceAfterUnderlyingGuard,
            "tc010:expected-lp-guard-baseline-to-match-underlying-guarded-quote"
        );
        assertEq(
            storedLpGuard.basePrice,
            lpGuardCap,
            "tc010:expected-volatile-lp-usd-guard-to-be-stored"
        );
        assertEq(
            expectedLpPriceIfAdjusted,
            lpGuardCap,
            "tc010:expected-post-fix-shape-to-clamp-final-lp-quote-to-guard-cap"
        );

        (uint256 lpPriceAfterLpGuard, uint256 lpErrorAfterLpGuard) =
            _getVolatileLPUsdQuote();
        assertEq(
            lpErrorAfterLpGuard,
            0,
            "tc010:expected-clean-lp-usd-price-after-lp-guard"
        );
        assertEq(
            lpPriceAfterLpGuard,
            expectedLpPriceIfAdjusted,
            "tc010:expected-final-lp-quote-to-clamp-through-adjustPrice"
        );
        assertEq(
            lpPriceAfterLpGuard,
            lpGuardCap,
            "tc010:expected-final-lp-quote-to-equal-the-stored-guard-cap"
        );
        assertLt(
            lpPriceAfterLpGuard,
            lpPriceBeforeLpGuard,
            "tc010:expected-final-lp-quote-to-clamp-below-the-underlying-guarded-baseline"
        );
    }

    function testPriceGuard_finalVolatileLpUsdQuoteReturnsErrorWhenGuardMinExceedsComposedQuote()
        public
    {
        (uint256 lpPriceBefore, uint256 lpErrorBefore) = _getVolatileLPUsdQuote();
        assertEq(lpErrorBefore, 0, "tc011:expected-clean-lp-usd-price");
        assertGt(lpPriceBefore, 0, "tc011:missing-volatile-lp-price");

        adaptor.setGuardedPriceConfig(
            _VELODROME_WETH_USDC,
            true,
            0,
            0,
            lpPriceBefore,
            lpPriceBefore
        );

        BaseOracleAdaptor.PriceGuard memory storedLpGuard = adaptor
            .getPriceGuard(_VELODROME_WETH_USDC, true);
        assertEq(
            storedLpGuard.basePrice,
            lpPriceBefore,
            "tc011:expected-volatile-lp-base-guard-to-match-current-quote"
        );
        assertEq(
            storedLpGuard.minPrice,
            lpPriceBefore,
            "tc011:expected-volatile-lp-min-guard-to-match-current-quote"
        );

        (uint256 wethPriceBefore, uint256 wethErrorBefore) = oracleManager
            .getPrice(_WETH_ADDRESS, true, false);
        assertEq(
            wethErrorBefore,
            0,
            "tc011:expected-clean-underlying-weth-usd-price"
        );
        assertGt(wethPriceBefore, 0, "tc011:missing-underlying-weth-price");

        uint256 wethGuardCap = wethPriceBefore / 2;
        chainlinkAdaptor.setGuardedPriceConfig(
            _WETH_ADDRESS,
            true,
            0,
            0,
            wethGuardCap,
            0
        );

        BaseOracleAdaptor.PriceGuard memory storedWethGuard = chainlinkAdaptor
            .getPriceGuard(_WETH_ADDRESS, true);
        (uint256 wethPriceAfter, uint256 wethErrorAfter) = oracleManager
            .getPrice(_WETH_ADDRESS, true, false);
        assertEq(
            wethErrorAfter,
            0,
            "tc011:expected-clean-underlying-weth-usd-price-after-guard"
        );
        assertEq(
            wethPriceAfter,
            _expectedStaticGuardedPrice(wethPriceBefore, storedWethGuard),
            "tc011:expected-underlying-weth-pricing-to-still-bind-through-oracle-manager"
        );

        IOracleAdaptor.PricingResult memory adaptorResult = adaptor.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertTrue(
            adaptorResult.hadError,
            "tc011:expected-final-lp-adaptor-call-to-signal-an-error"
        );
        assertTrue(
            adaptorResult.inUSD,
            "tc011:expected-final-lp-adaptor-call-to-stay-in-usd-mode"
        );
        assertEq(
            adaptorResult.price,
            0,
            "tc011:expected-final-lp-adaptor-call-to-return-zero-after-guard-rejection"
        );

        (uint256 lpPriceAfter, uint256 lpErrorAfter) = _getVolatileLPUsdQuote();
        assertEq(
            lpPriceAfter,
            0,
            "tc011:expected-oracle-manager-lp-price-to-zero-when-the-adaptor-errors"
        );
        assertGt(
            lpErrorAfter,
            0,
            "tc011:expected-oracle-manager-to-bubble-the-adaptor-error"
        );
    }

    function testRevertGetPrice__AssetIsNotSupported() public {
        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector
        );
        adaptor.getPrice(address(0), true, false);
    }

    function testRevertRemoveAsset__AssetIsNotSupported() public {
        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector
        );
        adaptor.removeAsset(address(0));
    }

    function testRevertAddAsset__ZeroAddress() public {
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        adaptor.addAsset(address(0));
    }
}
