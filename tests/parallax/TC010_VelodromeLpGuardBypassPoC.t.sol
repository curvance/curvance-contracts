// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { TestVelodromeVolatileLPAdaptor } from "tests/oracles/OracleManager/integrations/TestVelodromeVolatileLPAdaptor.t.sol";
import { TestVelodromeStableLPAdaptor } from "tests/oracles/OracleManager/integrations/TestVelodromeStableLPAdaptor.t.sol";

contract TC010VelodromeVolatileLpGuardBypassPoC is
    TestVelodromeVolatileLPAdaptor
{
    function test_tc010_velodromeVolatileLpUsdGuardCanBeStoredYetStayInert()
        public
    {
        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorBefore, 0, "tc010:expected-clean-usd-price");
        assertGt(priceBefore, 0, "tc010:missing-volatile-lp-price");

        uint256 guardCap = priceBefore / 2;
        adaptor.setGuardedPriceConfig(
            _VELODROME_WETH_USDC,
            true,
            0,
            0,
            guardCap,
            0
        );

        BaseOracleAdaptor.PriceGuard memory storedGuard = adaptor.getPriceGuard(
            _VELODROME_WETH_USDC,
            true
        );
        assertEq(
            storedGuard.basePrice,
            guardCap,
            "tc010:expected-volatile-usd-guard-to-be-stored"
        );

        (uint256 priceAfter, uint256 errorAfter) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorAfter, 0, "tc010:expected-clean-usd-price-after-guard");
        assertEq(
            priceAfter,
            priceBefore,
            "tc010:volatile-lp-price-changed-even-though-direct-getPrice-bypasses-base-adjustment"
        );
        assertGt(
            priceAfter,
            guardCap,
            "tc010:volatile-lp-guard-cap-should-have-clamped-if-it-bound-runtime"
        );
    }
}

contract TC010VelodromeStableLpGuardBypassPoC is TestVelodromeStableLPAdaptor {
    function test_tc010_velodromeStableLpUsdGuardCanBeStoredYetStayInert()
        public
    {
        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorBefore, 0, "tc010:expected-clean-usd-price");
        assertGt(priceBefore, 0, "tc010:missing-stable-lp-price");

        uint256 guardCap = priceBefore / 2;
        adaptor.setGuardedPriceConfig(
            _VELODROME_DAI_USDC,
            true,
            0,
            0,
            guardCap,
            0
        );

        BaseOracleAdaptor.PriceGuard memory storedGuard = adaptor.getPriceGuard(
            _VELODROME_DAI_USDC,
            true
        );
        assertEq(
            storedGuard.basePrice,
            guardCap,
            "tc010:expected-stable-usd-guard-to-be-stored"
        );

        (uint256 priceAfter, uint256 errorAfter) = oracleManager.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorAfter, 0, "tc010:expected-clean-usd-price-after-guard");
        assertEq(
            priceAfter,
            priceBefore,
            "tc010:stable-lp-price-changed-even-though-direct-getPrice-bypasses-base-adjustment"
        );
        assertGt(
            priceAfter,
            guardCap,
            "tc010:stable-lp-guard-cap-should-have-clamped-if-it-bound-runtime"
        );
    }
}
