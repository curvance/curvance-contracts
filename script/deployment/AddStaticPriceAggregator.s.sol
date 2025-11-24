// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { StaticPriceAggregator } from "contracts/oracles/adaptors/wrappedAggregators/StaticPriceAggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

// Minimal implemented implementation.
contract ImplementedStaticPriceAggregator is StaticPriceAggregator {
    constructor(uint256 staticPrice) StaticPriceAggregator(staticPrice) {
    }
}

contract AddStaticPriceAggregator is DeployScript {
    function run(
        address asset,
        uint256 staticPrice,
        address adaptorAddress,
        address oracleManager,
        uint256 heartbeat,
        bool inUSD
    ) external recordEvents {
        
        address agg = address(new ImplementedStaticPriceAggregator(staticPrice));
        emit ContractDeployed(agg, "StaticPriceAggregator");

        // Register on chainlink adaptor and OracleManager
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptorAddress);
        adaptor.addAsset(asset, inUSD, agg, heartbeat);

        OracleManager manager = OracleManager(oracleManager);
        manager.addAssetPricingAdaptor(asset, address(adaptor), 250, 220, 250, 220);
    }
}
