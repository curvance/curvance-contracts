// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddRedstoneSupport is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    struct PullFeed {
        bytes payload;
        uint128 timestamp;
    }

    struct PushFeed {
        bool inUSD;
        address feed;
        uint256 heartbeat;
        string id;
    }

    function run(
        address asset,
        address adaptor,
        address oracleManager,
        PushFeed memory feed
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        RedstoneClassicAdaptor adaptor = RedstoneClassicAdaptor(adaptor);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

        adaptor.addAsset(asset, feed.inUSD, feed.feed, feed.heartbeat, feed.id);
        manager.addAssetPriceFeed(asset, address(adaptor));

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
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

        RedstoneCoreAdaptor adaptor = RedstoneCoreAdaptor(adaptor);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

        // Add oracle support
        adaptor.addAsset(asset, true, token.decimals(), 10 minutes);
        adaptor.assetConfig(asset, true);

        // Push the first price on-chain
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint128)",
            asset,
            true,
            feed.timestamp
        );
        bytes memory write = abi.encodePacked(encodedFunction, feed.payload);
        (bool success, ) = address(adaptor).call(write);
        require(success, "Failed to write price");

        // Finalize oracle support
        manager.addAssetPriceFeed(asset, address(adaptor));

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
