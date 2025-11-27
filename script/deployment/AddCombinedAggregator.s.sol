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

    function run(
        address asset,
        address centralRegistry,
        address primaryAggregator,
        address secondaryAggregator,
        uint256 secondaryHeartbeat,
        address adaptorAddress,
        address oracleManager,
        string memory assetId,
        uint256 heartbeat,
        bool inUSD,
        PriceGuard memory adaptorGuardConfig,
        PriceGuard memory combinedGuardConfig
    ) external recordEvents {
        IERC20 token = IERC20(asset);
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

        // Register on chainlink adaptor and OracleManager
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptorAddress);
        adaptor.addAsset(asset, inUSD, agg, heartbeat);

        OracleManager manager = OracleManager(oracleManager);
        manager.addAssetPricingAdaptor(asset, address(adaptor), 250, 220, 250, 220);

        // First: apply adaptor-level PriceGuard on ChainlinkAdaptor
        if(adaptorGuardConfig.enabled) {
            adaptor.setGuardedPriceConfig(
                asset,
                adaptorGuardConfig.inUSD,
                adaptorGuardConfig.ips > 0 ? block.timestamp - adaptorGuardConfig.timestampSubtract : 0,
                adaptorGuardConfig.ips,
                adaptorGuardConfig.basePrice,
                adaptorGuardConfig.minPrice
            );
        }

        // Second: apply PriceGuard on CombinedAggregator
        if (combinedGuardConfig.enabled) {
            CombinedAggregator(agg).setGuardedPriceConfig(
                combinedGuardConfig.ips > 0 ? block.timestamp - combinedGuardConfig.timestampSubtract : 0,
                combinedGuardConfig.ips,
                combinedGuardConfig.basePrice,
                combinedGuardConfig.minPrice
            );
        }
        
    }
}
