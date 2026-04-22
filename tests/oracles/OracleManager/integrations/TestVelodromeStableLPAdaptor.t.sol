// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { BaseStableLPAdaptor } from "contracts/oracles/adaptors/stableswapBase/BaseStableLPAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestVelodromeStableLPAdaptor is TestBaseOracleManager {
    address internal _VELO_ROUTER = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address internal _VELODROME_DAI_USDC =
        0x19715771E30c93915A5bbDa134d782b81A820076;

    VelodromeStableLPAdaptor public adaptor;

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 110333246);

        _deployCentralRegistry();
        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        adaptor.addAsset(_VELODROME_DAI_USDC);

        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            _CHAINLINK_DAI_USD,
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
            _DAI_ADDRESS,
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
            _VELODROME_DAI_USDC,
            address(adaptor),
            100,
            50,
            100,
            50
        );
    }

    function _getStableLPUsdQuote()
        internal
        view
        returns (uint256 price, uint256 errorCode)
    {
        (price, errorCode) = oracleManager.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
    }

    function _storeUsdGuardAtHalfCurrentStableLpQuote()
        internal
        returns (
            uint256 priceBefore,
            uint256 guardCap,
            BaseOracleAdaptor.PriceGuard memory storedGuard
        )
    {
        uint256 errorCode;
        (priceBefore, errorCode) = _getStableLPUsdQuote();
        assertEq(errorCode, 0, "expected clean LP USD price");
        assertGt(priceBefore, 0, "missing stable LP price");

        guardCap = priceBefore / 2;
        adaptor.setGuardedPriceConfig(
            _VELODROME_DAI_USDC,
            true,
            0,
            0,
            guardCap,
            0
        );

        storedGuard = adaptor.getPriceGuard(_VELODROME_DAI_USDC, true);
    }

    // Mirrors the static clamp path that should apply once the final LP quote
    // flows through BaseOracleAdaptor guard adjustment.
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
        chainlinkAdaptor.removeAsset(_DAI_ADDRESS);

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_VELODROME_DAI_USDC, true, false);
    }

    function testReturnsCorrectPrice() public view {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adaptor.removeAsset(_VELODROME_DAI_USDC);
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_VELODROME_DAI_USDC, true, false);
    }

    function testRevertAddAsset__AssetIsNotStableLP() public {
        vm.expectRevert(
            BaseStableLPAdaptor.BaseStableLPAdaptor__InvalidAssetType.selector
        );
        adaptor.addAsset(0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b);
    }

    function testCanUpdateAsset() public {
        adaptor.addAsset(_VELODROME_DAI_USDC);
        adaptor.addAsset(_VELODROME_DAI_USDC);
    }

    function testPriceGuard_finalStableLpUsdQuoteClampsThroughBaseAdjustPrice()
        public
    {
        (
            uint256 priceBefore,
            uint256 guardCap,
            BaseOracleAdaptor.PriceGuard memory storedGuard
        ) = _storeUsdGuardAtHalfCurrentStableLpQuote();

        assertEq(
            storedGuard.basePrice,
            guardCap,
            "expected stable LP USD guard to be stored"
        );

        uint256 expectedPostFixQuote =
            _expectedStaticGuardedPrice(priceBefore, storedGuard);
        assertEq(
            expectedPostFixQuote,
            guardCap,
            "post-fix final LP quote should clamp to stored LP guard cap"
        );

        (uint256 priceAfter, uint256 errorAfter) = _getStableLPUsdQuote();
        assertEq(errorAfter, 0, "expected clean LP USD price after guard");
        assertEq(
            priceAfter,
            expectedPostFixQuote,
            "expected final stable LP USD quote to clamp through BaseOracleAdaptor._adjustPrice"
        );
        assertEq(
            priceAfter,
            guardCap,
            "expected final stable LP USD quote to equal the stored LP guard cap"
        );
        assertLt(
            priceAfter,
            priceBefore,
            "expected final stable LP USD quote to clamp below the pre-guard quote"
        );
    }

    function testPriceGuard_finalStableLpUsdQuoteReturnsErrorWhenGuardMinExceedsComposedQuote()
        public
    {
        (uint256 lpPriceBefore, uint256 lpErrorBefore) = _getStableLPUsdQuote();
        assertEq(lpErrorBefore, 0, "expected clean stable LP USD price");
        assertGt(lpPriceBefore, 0, "missing stable LP price");

        adaptor.setGuardedPriceConfig(
            _VELODROME_DAI_USDC,
            true,
            0,
            0,
            lpPriceBefore,
            lpPriceBefore
        );

        BaseOracleAdaptor.PriceGuard memory storedLpGuard = adaptor
            .getPriceGuard(_VELODROME_DAI_USDC, true);
        assertEq(
            storedLpGuard.basePrice,
            lpPriceBefore,
            "expected stable LP base guard to match current quote"
        );
        assertEq(
            storedLpGuard.minPrice,
            lpPriceBefore,
            "expected stable LP min guard to match current quote"
        );

        (uint256 daiPriceBefore, uint256 daiErrorBefore) = oracleManager
            .getPrice(_DAI_ADDRESS, true, false);
        assertEq(daiErrorBefore, 0, "expected clean DAI USD price");
        assertGt(daiPriceBefore, 0, "missing DAI USD price");

        uint256 daiGuardCap = daiPriceBefore / 2;
        chainlinkAdaptor.setGuardedPriceConfig(
            _DAI_ADDRESS,
            true,
            0,
            0,
            daiGuardCap,
            0
        );

        BaseOracleAdaptor.PriceGuard memory storedDaiGuard = chainlinkAdaptor
            .getPriceGuard(_DAI_ADDRESS, true);
        (uint256 daiPriceAfter, uint256 daiErrorAfter) = oracleManager
            .getPrice(_DAI_ADDRESS, true, false);
        assertEq(daiErrorAfter, 0, "expected clean DAI USD price after guard");
        assertEq(
            daiPriceAfter,
            _expectedStaticGuardedPrice(daiPriceBefore, storedDaiGuard),
            "expected underlying DAI pricing to still bind through oracle manager"
        );

        IOracleAdaptor.PricingResult memory adaptorResult = adaptor.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertTrue(
            adaptorResult.hadError,
            "expected stable LP adaptor call to signal an error"
        );
        assertTrue(
            adaptorResult.inUSD,
            "expected stable LP adaptor call to stay in usd mode"
        );
        assertEq(
            adaptorResult.price,
            0,
            "expected stable LP adaptor call to return zero after guard rejection"
        );

        (uint256 lpPriceAfter, uint256 lpErrorAfter) = _getStableLPUsdQuote();
        assertEq(
            lpPriceAfter,
            0,
            "expected oracle manager stable LP price to zero when the adaptor errors"
        );
        assertGt(
            lpErrorAfter,
            0,
            "expected oracle manager to bubble the stable LP adaptor error"
        );
    }

    function testPriceDoesNotChangeAfterLargeSwap() public {
        uint256 errorCode;
        uint256 priceBefore;
        (priceBefore, errorCode) = oracleManager.getPrice(
            _VELODROME_DAI_USDC,
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
            _VELODROME_DAI_USDC,
            _USDC_ADDRESS,
            _DAI_ADDRESS,
            amount,
            true
        );

        assertEq(usdc.balanceOf(address(this)), 0);
        assertGt(dai.balanceOf(address(this)), 0);

        uint256 priceAfter;
        (priceAfter, errorCode) = oracleManager.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertApproxEqRel(priceBefore, priceAfter, 100);
    }

    function testPriceDoesNotChangeAfterTenTimesLargeSwap() public {
        uint256 errorCode;
        uint256 priceBefore;
        (priceBefore, errorCode) = oracleManager.getPrice(
            _VELODROME_DAI_USDC,
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
            _VELODROME_DAI_USDC,
            _USDC_ADDRESS,
            _DAI_ADDRESS,
            amount,
            true
        );

        assertEq(usdc.balanceOf(address(this)), 0);
        assertGt(dai.balanceOf(address(this)), 0);

        uint256 priceAfter;
        (priceAfter, errorCode) = oracleManager.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        // 1e-14% change is allowed, almost equal
        assertApproxEqRel(priceBefore, priceAfter, 100);
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
