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

    function run(
        address asset,
        address adaptorAddress,
        address oracleManager,
        PullFeed memory feed
    ) external recordEvents {
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptorAddress);
        adaptor.addAsset(asset, feed.inUSD, feed.aggregator, feed.heartbeat);
        manager.addAssetPricingAdaptor(asset, address(adaptor), 250, 220, 250, 220);
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
