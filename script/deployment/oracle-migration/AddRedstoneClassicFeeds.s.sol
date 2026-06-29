// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";

contract AddRedstoneClassicFeeds is DeployScript {
    struct DeviationBounds {
        uint256 badSourceUSD;
        uint256 cautionUSD;
        uint256 badSourceNative;
        uint256 cautionNative;
    }

    struct PriceGuard {
        bool enabled;
        bool inUSD;
        uint256 timestampStart;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    struct RedstoneClassicFeed {
        address asset;
        bool inUSD;
        address feedProxy;
        uint256 heartbeat;
        string dataFeedId;
        DeviationBounds bounds;
        PriceGuard guard;
    }

    function run(
        address oracleManager,
        address redstoneClassicAdaptor,
        RedstoneClassicFeed[] calldata feeds
    ) external recordEvents {
        OracleManager manager = OracleManager(oracleManager);
        RedstoneClassicAdaptor adaptor = RedstoneClassicAdaptor(redstoneClassicAdaptor);

        for (uint256 i; i < feeds.length; ++i) {
            RedstoneClassicFeed calldata feed = feeds[i];
            adaptor.addAsset(feed.asset, feed.inUSD, feed.feedProxy, feed.heartbeat, feed.dataFeedId);
            _setGuardedPriceConfig(BaseOracleAdaptor(redstoneClassicAdaptor), feed.asset, feed.guard);
            manager.addAssetPricingAdaptor(
                feed.asset,
                redstoneClassicAdaptor,
                feed.bounds.badSourceUSD,
                feed.bounds.cautionUSD,
                feed.bounds.badSourceNative,
                feed.bounds.cautionNative
            );
        }
    }

    function _setGuardedPriceConfig(
        BaseOracleAdaptor adaptor,
        address asset,
        PriceGuard calldata guard
    ) internal {
        if (!guard.enabled) {
            return;
        }

        adaptor.setGuardedPriceConfig(
            asset,
            guard.inUSD,
            guard.timestampStart,
            guard.ips,
            guard.basePrice,
            guard.minPrice
        );
    }
}
