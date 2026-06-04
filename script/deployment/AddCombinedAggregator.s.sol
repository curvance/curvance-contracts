// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract AddCombinedAggregator is DeployScript {
    struct PriceGuard {
        bool enabled;
        bool inUSD;
        uint256 timestampSubtract;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    error AddCombinedAggregator__UnsupportedOracleRoute();
    error AddCombinedAggregator__Unauthorized();

    function run(
        address asset,
        // ====== CombinedAggregator Parameters ======
        address centralRegistry,
        address primaryAggregator,
        address secondaryAggregator,
        uint256 secondaryHeartbeat,
        string memory assetId,
        PriceGuard memory combinedGuardConfig,
        // ====== ChainlinkAdaptor Parameters ======
        address adaptorAddress,
        uint256 heartbeat
    ) external recordEvents {
        IERC20 token = IERC20(asset);
        _checkOracleManagerRoutesThroughAdaptor(
            OracleManager(ICentralRegistry(centralRegistry).oracleManager()),
            asset,
            adaptorAddress
        );
        _checkDeploymentPermissions(ICentralRegistry(centralRegistry));

        // ====== Deploy and configure CombinedAggregator ======
        address agg = address(
            new CombinedAggregator(
                ICentralRegistry(address(centralRegistry)),
                primaryAggregator,
                secondaryAggregator,
                secondaryHeartbeat,
                assetId
            )
        );
        emit ContractDeployed(agg, string.concat("CombinedAggregator-", token.symbol()));

        // Configure PriceGuard on CombinedAggregator
        if (combinedGuardConfig.enabled) {
            CombinedAggregator(agg).setGuardedPriceConfig(
                combinedGuardConfig.ips > 0 ? block.timestamp - combinedGuardConfig.timestampSubtract : 0,
                combinedGuardConfig.ips,
                combinedGuardConfig.basePrice,
                combinedGuardConfig.minPrice
            );
        }

        // ====== Re-configure ChainlinkAdaptor ======

        // Start adaptor instance
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptorAddress);

        // Update adaptor to use new CombinedAggregator
        adaptor.addAsset(asset, true, agg, heartbeat);

        // remove priceguard from adaptor level
        adaptor.disableGuardedPriceConfig(asset, true);
    }

    function _checkOracleManagerRoutesThroughAdaptor(
        OracleManager oracleManager,
        address asset,
        address adaptorAddress
    ) internal view {
        address[] memory adaptors = oracleManager.getPricingAdaptors(asset);
        if (adaptors.length > 0 && adaptors[0] == adaptorAddress) {
            return;
        }

        revert AddCombinedAggregator__UnsupportedOracleRoute();
    }

    function _checkDeploymentPermissions(
        ICentralRegistry centralRegistry
    ) internal {
        (, address deploymentCaller, ) = vm.readCallers();
        if (
            !centralRegistry.hasElevatedPermissions(deploymentCaller) ||
            !centralRegistry.hasMarketPermissions(deploymentCaller)
        ) {
            revert AddCombinedAggregator__Unauthorized();
        }
    }
}
