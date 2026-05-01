// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestPendleLPTokenAdaptor } from "tests/oracles/OracleManager/integrations/TestPendleLPTokenAdaptor.t.sol";

/// @title Pendle LP guard-binding regression
/// @notice Pins the direct override path through `_adjustPrice` so a configured
///         USD `PriceGuard` clamps the runtime adaptor price.
contract TestPendleLPGuardBinding is TestPendleLPTokenAdaptor {
    function test_pendleLpUsdGuard_clampsRuntimePrice() public {
        _configurePendleLpUsdPricing();

        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _LP_STETH,
            true,
            false
        );
        assertEq(errorBefore, 0, "pendle-lp-guard:expected-clean-usd-price");
        assertGt(priceBefore, 0, "pendle-lp-guard:missing-lp-price");

        // Configure a guard cap at half the current price. Pre-fix the
        // guard storage would succeed but be silently inert at runtime;
        // post-fix `_adjustPrice` clamps the returned price to basePrice.
        uint256 guardCap = priceBefore / 2;
        adapter.setGuardedPriceConfig(
            _LP_STETH,
            true,
            0,
            0,
            guardCap,
            0
        );

        BaseOracleAdaptor.PriceGuard memory storedGuard = adapter.getPriceGuard(
            _LP_STETH,
            true
        );
        assertEq(
            storedGuard.basePrice,
            guardCap,
            "pendle-lp-guard:expected-usd-guard-to-be-stored"
        );

        (uint256 priceAfter, uint256 errorAfter) = oracleManager.getPrice(
            _LP_STETH,
            true,
            false
        );
        assertEq(errorAfter, 0, "pendle-lp-guard:expected-clean-usd-price-after-guard");

        // Post-fix invariants: priceAfter MUST equal `guardCap` (clamp
        // bound the price to basePrice) and MUST be strictly less than
        // `priceBefore` (clamp actually reduced the value, not just no-op).
        assertEq(
            priceAfter,
            guardCap,
            "pendle-lp-guard:guard-MUST-clamp-price-to-basePrice"
        );
        assertLt(
            priceAfter,
            priceBefore,
            "pendle-lp-guard:clamp-MUST-have-reduced-price-from-raw-to-cap"
        );
    }

    function _configurePendleLpUsdPricing() internal {
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
            _CHAINLINK_STETH_USD,
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

        PendleLPTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.pt = _PT_STETH;
        assetConfig.quoteAssetDecimals = 18;
        adapter.addAsset(_LP_STETH, assetConfig);

        oracleManager.addApprovedAdaptor(address(adapter));
        oracleManager.addAssetPricingAdaptor(
            _LP_STETH,
            address(adapter),
            100,
            50,
            100,
            50
        );
    }
}
