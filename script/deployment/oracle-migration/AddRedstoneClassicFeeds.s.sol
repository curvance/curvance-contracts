// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../../utils/DeployScript.sol";
import {
    OracleDeploymentPreflight
} from "../../utils/OracleDeploymentPreflight.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {
    BaseOracleAdaptor
} from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import {
    RedstoneClassicAdaptor
} from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";

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
        _validatePreflight(oracleManager, redstoneClassicAdaptor, feeds);

        OracleManager manager = OracleManager(oracleManager);
        RedstoneClassicAdaptor adaptor =
            RedstoneClassicAdaptor(redstoneClassicAdaptor);

        for (uint256 i; i < feeds.length; ++i) {
            RedstoneClassicFeed calldata feed = feeds[i];
            adaptor.addAsset(
                feed.asset,
                feed.inUSD,
                feed.feedProxy,
                feed.heartbeat,
                feed.dataFeedId
            );
            BaseOracleAdaptor baseAdaptor =
                BaseOracleAdaptor(redstoneClassicAdaptor);
            _setGuardedPriceConfig(baseAdaptor, feed.asset, feed.guard);
            _addAssetPricingAdaptor(manager, baseAdaptor, feed);
        }
    }

    function _validatePreflight(
        address oracleManager,
        address redstoneClassicAdaptor,
        RedstoneClassicFeed[] calldata feeds
    ) internal view {
        OracleDeploymentPreflight.requireContract(oracleManager);
        OracleDeploymentPreflight.requireContract(redstoneClassicAdaptor);
        OracleDeploymentPreflight.requireNonEmpty(feeds.length);

        OracleManager manager = OracleManager(oracleManager);

        for (uint256 i; i < feeds.length; ++i) {
            RedstoneClassicFeed calldata feed = feeds[i];
            OracleDeploymentPreflight.requireNonZero(feed.asset);
            OracleDeploymentPreflight.requireContract(feed.feedProxy);
            OracleDeploymentPreflight.requireHeartbeat(feed.heartbeat);
            OracleDeploymentPreflight.requireNonEmptyString(feed.dataFeedId);
            OracleDeploymentPreflight.validateSecondAdaptorDeviationBounds(
                OracleDeploymentPreflight.willSetDeviationBoundsOnAdd(
                    manager, feed.asset
                ),
                feed.bounds.badSourceUSD,
                feed.bounds.cautionUSD,
                feed.bounds.badSourceNative,
                feed.bounds.cautionNative
            );
            OracleDeploymentPreflight.validateAbsoluteGuardIfEnabled(
                feed.guard.enabled,
                feed.guard.timestampStart,
                feed.guard.ips,
                feed.guard.basePrice,
                feed.guard.minPrice
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

        try adaptor.setGuardedPriceConfig(
            asset,
            guard.inUSD,
            guard.timestampStart,
            guard.ips,
            guard.basePrice,
            guard.minPrice
        ) {}
        catch (bytes memory revertData) {
            adaptor.removeAsset(asset);
            _revertWithData(revertData);
        }
    }

    function _addAssetPricingAdaptor(
        OracleManager manager,
        BaseOracleAdaptor adaptor,
        RedstoneClassicFeed calldata feed
    ) internal {
        try manager.addAssetPricingAdaptor(
            feed.asset,
            address(adaptor),
            feed.bounds.badSourceUSD,
            feed.bounds.cautionUSD,
            feed.bounds.badSourceNative,
            feed.bounds.cautionNative
        ) {}
        catch (bytes memory revertData) {
            adaptor.removeAsset(feed.asset);
            _revertWithData(revertData);
        }
    }

    function _revertWithData(bytes memory revertData) internal pure {
        if (revertData.length == 0) {
            revert("oracle migration failed");
        }

        assembly {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }
}
