// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { HEARTBEAT_GRACE_PERIOD } from "contracts/libraries/ConstantsLib.sol";

contract AddChainLinkSupport is DeployScript {
    struct PullFeed {
        address aggregator;
        uint256 heartbeat;
        bool inUSD;
    }

    struct PriceGuard {
        bool enabled;
        bool inUSD;
        uint256 timestampSubtract;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    function run(
        address asset,
        address adaptorAddress,
        address oracleManager,
        PullFeed memory feed,
        PriceGuard memory guardConfig
    ) external recordEvents {
        OracleManager manager = OracleManager(oracleManager);
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptorAddress);

        adaptor.addAsset(asset, feed.inUSD, feed.aggregator, feed.heartbeat);

        // Verify asset was added to adaptor
        _verifyChainlinkAssetConfig(adaptor, asset, feed);

        manager.addAssetPricingAdaptor(asset, address(adaptor), 250, 220, 250, 220);

        // Verify adaptor was added to OracleManager for the asset
        _verifyAssetPricingAdaptor(manager, asset, address(adaptor));

        if (guardConfig.enabled) {
            uint256 timestampStart = guardConfig.ips > 0 ? block.timestamp - guardConfig.timestampSubtract : 0;
            adaptor.setGuardedPriceConfig(
                asset,
                guardConfig.inUSD,
                timestampStart,
                guardConfig.ips,
                guardConfig.basePrice,
                guardConfig.minPrice
            );

            // Verify price guard config was set
            _verifyPriceGuardConfig(adaptor, asset, guardConfig, timestampStart);
        }
    }

    /// @notice Verifies Chainlink asset configuration was set correctly
    function _verifyChainlinkAssetConfig(
        ChainlinkAdaptor adaptor,
        address asset,
        PullFeed memory feed
    ) internal view {
        // Verify asset is supported
        require(
            adaptor.isSupportedAsset(asset),
            "AddChainLinkSupport: Asset not supported by adaptor"
        );

        // Get the asset config
        (
            bool isConfigured,
            IChainlink aggregatorProxy,
            uint8 decimals,
            uint24 heartbeat
        ) = adaptor.assetConfig(asset, feed.inUSD);

        // Verify isConfigured
        require(
            isConfigured,
            "AddChainLinkSupport: Asset config not configured"
        );

        // Verify aggregator proxy
        require(
            address(aggregatorProxy) == feed.aggregator,
            "AddChainLinkSupport: Aggregator proxy mismatch"
        );

        // Verify decimals match the aggregator's decimals
        require(
            decimals == IChainlink(feed.aggregator).decimals(),
            "AddChainLinkSupport: Decimals mismatch"
        );

        // Verify heartbeat
        // If feed.heartbeat == 0, it uses DEFAULT_HEARTBEAT (1 days + HEARTBEAT_GRACE_PERIOD)
        // Otherwise it's feed.heartbeat + HEARTBEAT_GRACE_PERIOD
        uint256 expectedHeartbeat;
        if (feed.heartbeat == 0) {
            expectedHeartbeat = 1 days + HEARTBEAT_GRACE_PERIOD;
        } else {
            expectedHeartbeat = feed.heartbeat + HEARTBEAT_GRACE_PERIOD;
        }
        require(
            heartbeat == expectedHeartbeat,
            "AddChainLinkSupport: Heartbeat mismatch"
        );
    }

    /// @notice Verifies asset pricing adaptor was added to OracleManager
    function _verifyAssetPricingAdaptor(
        OracleManager manager,
        address asset,
        address adaptor
    ) internal view {
        // Get the pricing adaptors for the asset
        address[] memory adaptors = manager.getPricingAdaptors(asset);

        // Verify at least one adaptor is configured
        require(
            adaptors.length > 0,
            "AddChainLinkSupport: No adaptors configured for asset"
        );

        // Verify the adaptor is in the list (should be the last one added)
        bool found = false;
        for (uint256 i = 0; i < adaptors.length; i++) {
            if (adaptors[i] == adaptor) {
                found = true;
                break;
            }
        }
        require(
            found,
            "AddChainLinkSupport: Adaptor not found in asset pricing config"
        );
    }

    /// @notice Verifies price guard configuration was set correctly
    function _verifyPriceGuardConfig(
        ChainlinkAdaptor adaptor,
        address asset,
        PriceGuard memory guardConfig,
        uint256 expectedTimestampStart
    ) internal view {
        // Get the price guard config
        (
            uint40 timestampStart,
            uint40 ips,
            uint88 basePrice,
            uint88 minPrice
        ) = adaptor.priceGuards(asset, guardConfig.inUSD);

        // Verify timestampStart
        require(
            timestampStart == expectedTimestampStart,
            "AddChainLinkSupport: PriceGuard timestampStart mismatch"
        );

        // Verify ips
        require(
            ips == guardConfig.ips,
            "AddChainLinkSupport: PriceGuard ips mismatch"
        );

        // Verify basePrice
        require(
            basePrice == guardConfig.basePrice,
            "AddChainLinkSupport: PriceGuard basePrice mismatch"
        );

        // Verify minPrice
        require(
            minPrice == guardConfig.minPrice,
            "AddChainLinkSupport: PriceGuard minPrice mismatch"
        );
    }

    function deployChainlinkAdaptor(
        ICentralRegistry icr,
        OracleManager oracleManager
    ) public useDeployer returns (ChainlinkAdaptor) {
        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(icr);

        // Verify adaptor deployment
        _verifyChainlinkAdaptorDeployment(chainlinkAdaptor, icr);

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        // Verify adaptor was approved in OracleManager
        require(
            oracleManager.isApprovedAdaptor(address(chainlinkAdaptor)),
            "AddChainLinkSupport: Adaptor not approved in OracleManager"
        );

        emit ContractDeployed(address(chainlinkAdaptor), "adaptors.ChainlinkAdaptor");

        return chainlinkAdaptor;
    }

    /// @notice Verifies ChainlinkAdaptor deployment state
    function _verifyChainlinkAdaptorDeployment(
        ChainlinkAdaptor adaptor,
        ICentralRegistry expectedRegistry
    ) internal view {
        // Verify centralRegistry
        require(
            address(adaptor.centralRegistry()) == address(expectedRegistry),
            "AddChainLinkSupport: Adaptor centralRegistry mismatch"
        );

        // Verify adaptor type is correct (keccak256("ChainlinkAdaptor"))
        require(
            adaptor.adaptorType() == uint256(keccak256("ChainlinkAdaptor")),
            "AddChainLinkSupport: Adaptor type mismatch"
        );

        // Verify DEFAULT_HEARTBEAT constant
        require(
            adaptor.DEFAULT_HEARTBEAT() == 1 days + HEARTBEAT_GRACE_PERIOD,
            "AddChainLinkSupport: DEFAULT_HEARTBEAT mismatch"
        );
    }
}
