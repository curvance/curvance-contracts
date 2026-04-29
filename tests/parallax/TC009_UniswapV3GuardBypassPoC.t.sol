// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { TestUniswapV3Adaptor } from "tests/oracles/OracleManager/integrations/TestUniswapV3Adaptor.t.sol";

/// @title TC009 — UniswapV3 guard-binding regression
/// @notice Originally a PoC for the `UniswapV3Adaptor.getPrice`
///         direct-override bypass at lines 160/184/189; now a regression
///         sentinel pinning the post-fix clamp behavior. See TC007 file
///         natspec for the full provenance note.
contract TC009UniswapV3GuardBypassPoC is TestUniswapV3Adaptor {
    function test_tc009_uniswapV3UsdGuard_clampsRuntimePrice() public {
        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorBefore, 0, "tc009:expected-clean-usd-price");
        assertGt(priceBefore, 0, "tc009:missing-wbtc-price");

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
            "tc009:expected-usd-guard-to-be-stored"
        );

        (uint256 priceAfter, uint256 errorAfter) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorAfter, 0, "tc009:expected-clean-usd-price-after-guard");

        // Post-fix invariants: priceAfter MUST equal `guardCap` (clamp
        // bound the price to basePrice) and MUST be strictly less than
        // `priceBefore` (clamp actually reduced the value, not just no-op).
        assertEq(
            priceAfter,
            guardCap,
            "tc009:guard-MUST-clamp-price-to-basePrice"
        );
        assertLt(
            priceAfter,
            priceBefore,
            "tc009:clamp-MUST-have-reduced-price-from-raw-to-cap"
        );
    }
}
