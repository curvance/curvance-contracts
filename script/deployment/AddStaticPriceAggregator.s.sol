// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { StaticPriceAggregator } from "contracts/oracles/adaptors/wrappedAggregators/StaticPriceAggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddStaticPriceAggregator is DeployScript {
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
        uint256 staticPrice,
        address adaptorAddress,
        address oracleManager,
        uint256 heartbeat,
        bool inUSD,
        PriceGuard memory guardConfig
    ) external recordEvents {
        IERC20 token = IERC20(asset);
        address agg = address(new StaticPriceAggregator(staticPrice));
        emit ContractDeployed(agg, string.concat("StaticPriceAggregator-", token.symbol()));

        // Register on chainlink adaptor and OracleManager
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptorAddress);
        adaptor.addAsset(asset, inUSD, agg, heartbeat);

        OracleManager manager = OracleManager(oracleManager);
        manager.addAssetPricingAdaptor(asset, address(adaptor), 250, 220, 250, 220);

        if(guardConfig.enabled) {
            adaptor.setGuardedPriceConfig(
                asset,
                guardConfig.inUSD,
                guardConfig.timestampSubtract > 0 ? block.timestamp - guardConfig.timestampSubtract : 0,
                guardConfig.ips,
                guardConfig.basePrice,
                guardConfig.minPrice
            );
        }
    }
}
