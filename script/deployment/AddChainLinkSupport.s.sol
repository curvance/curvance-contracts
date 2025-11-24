// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

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
        IERC20 token = IERC20(asset);
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptorAddress);
        adaptor.addAsset(asset, feed.inUSD, feed.aggregator, feed.heartbeat);
        manager.addAssetPricingAdaptor(asset, address(adaptor), 250, 220, 250, 220);

        if(guardConfig.enabled) {
            adaptor.setGuardedPriceConfig(
                asset,
                guardConfig.inUSD,
                guardConfig.ips > 0 ? block.timestamp - guardConfig.timestampSubtract : 0,
                guardConfig.ips,
                guardConfig.basePrice,
                guardConfig.minPrice
            );
        }
    }

    function deployChainlinkAdaptor(
        ICentralRegistry icr,
        OracleManager oracleManager
    ) public useDeployer returns (ChainlinkAdaptor) {
        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(icr);
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        emit ContractDeployed(address(chainlinkAdaptor), "adaptors.ChainlinkAdaptor");

        return chainlinkAdaptor;
    }
}
