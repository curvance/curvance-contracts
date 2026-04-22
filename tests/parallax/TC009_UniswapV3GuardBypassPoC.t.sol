// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { TestUniswapV3Adaptor } from "tests/oracles/OracleManager/integrations/TestUniswapV3Adaptor.t.sol";

contract TC009UniswapV3GuardBypassPoC is TestUniswapV3Adaptor {
    function test_tc009_uniswapV3UsdGuardCanBeStoredYetStayInertWhenAdaptorOverridesGetPrice()
        public
    {
        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorBefore, 0, "tc009:expected-clean-usd-price");
        assertGt(priceBefore, 0, "tc009:missing-wbtc-price");

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
        assertEq(
            priceAfter,
            priceBefore,
            "tc009:price-changed-even-though-direct-getPrice-bypasses-base-adjustment"
        );
        assertGt(
            priceAfter,
            guardCap,
            "tc009:guard-cap-should-have-clamped-if-it-bound-runtime"
        );
    }
}
