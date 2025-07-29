// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddChainLinkSupport is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;
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
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptor);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

        adaptor.addAsset(asset, feed.aggregator, feed.heartbeat, feed.inUSD);
        manager.addAssetPriceFeed(asset, address(adaptor));

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
