// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestPendleLPTokenAdaptor } from "tests/oracles/OracleManager/integrations/TestPendleLPTokenAdaptor.t.sol";

contract TC008PendleLpGuardBypassPoC is TestPendleLPTokenAdaptor {
    function test_tc008_pendleLpUsdGuardCanBeStoredYetStayInertWhenAdaptorOverridesGetPrice()
        public
    {
        _configurePendleLpUsdPricing();

        (uint256 priceBefore, uint256 errorBefore) = oracleManager.getPrice(
            _LP_STETH,
            true,
            false
        );
        assertEq(errorBefore, 0, "tc008:expected-clean-usd-price");
        assertGt(priceBefore, 0, "tc008:missing-lp-price");

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
            "tc008:expected-usd-guard-to-be-stored"
        );

        (uint256 priceAfter, uint256 errorAfter) = oracleManager.getPrice(
            _LP_STETH,
            true,
            false
        );
        assertEq(errorAfter, 0, "tc008:expected-clean-usd-price-after-guard");
        assertEq(
            priceAfter,
            priceBefore,
            "tc008:price-changed-even-though-direct-getPrice-bypasses-base-adjustment"
        );
        assertGt(
            priceAfter,
            guardCap,
            "tc008:guard-cap-should-have-clamped-if-it-bound-runtime"
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
