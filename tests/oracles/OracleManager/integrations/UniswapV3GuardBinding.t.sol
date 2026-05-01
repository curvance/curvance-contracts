// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { TestUniswapV3Adaptor } from "tests/oracles/OracleManager/integrations/TestUniswapV3Adaptor.t.sol";

/// @title UniswapV3 guard-binding regression
/// @notice Pins the direct override path through `_adjustPrice` so a configured
///         USD `PriceGuard` clamps the runtime adaptor price.
contract TestUniswapV3GuardBinding is TestUniswapV3Adaptor {
    function test_uniswapV3UsdGuard_clampsRuntimePrice() public {
        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorBefore, 0, "uniswap-v3-guard:expected-clean-usd-price");
        assertGt(priceBefore, 0, "uniswap-v3-guard:missing-wbtc-price");

        // Configure a guard cap at half the current price. Pre-fix the
        // guard storage would succeed but be silently inert at runtime;
        // post-fix `_adjustPrice` clamps the returned price to basePrice.
        uint256 guardCap = priceBefore / 2;
        adaptor.setGuardedPriceConfig(
            _WBTC_ADDRESS,
            true,
            0,
            0,
            guardCap,
            0
        );

        BaseOracleAdaptor.PriceGuard memory storedGuard = adaptor.getPriceGuard(
            _WBTC_ADDRESS,
            true
        );
        assertEq(
            storedGuard.basePrice,
            guardCap,
            "uniswap-v3-guard:expected-usd-guard-to-be-stored"
        );

        (uint256 priceAfter, uint256 errorAfter) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorAfter, 0, "uniswap-v3-guard:expected-clean-usd-price-after-guard");

        // Post-fix invariants: priceAfter MUST equal `guardCap` (clamp
        // bound the price to basePrice) and MUST be strictly less than
        // `priceBefore` (clamp actually reduced the value, not just no-op).
        assertEq(
            priceAfter,
            guardCap,
            "uniswap-v3-guard:guard-MUST-clamp-price-to-basePrice"
        );
        assertLt(
            priceAfter,
            priceBefore,
            "uniswap-v3-guard:clamp-MUST-have-reduced-price-from-raw-to-cap"
        );
    }
}
