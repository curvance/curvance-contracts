// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddChainLinkSupport is Script, DeploymentLogger {
    struct PullFeed {
        address aggregator;
        uint256 heartbeat;
        bool inUSD;
    }

    function run(
        address asset,
        address adaptor,
        address oracleManager,
        PullFeed memory feed
    ) external recordEvents {
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptor);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

        adaptor.addAsset(asset, feed.inUSD, feed.aggregator, feed.heartbeat);
        manager.addAssetPriceFeed(asset, address(adaptor));
    }
}
