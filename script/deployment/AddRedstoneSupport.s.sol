// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddRedstoneSupport is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        address asset,
        address adaptor,
        address oracleManager,
        bytes memory redstonePayload,
        uint128 redstoneTimestamp
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        RedstoneCoreAdaptor adaptor = RedstoneCoreAdaptor(adaptor);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

        // Add oracle support
        adaptor.addAsset(asset, true, token.decimals(), 10 minutes);
        adaptor.adaptorData(asset, true);

        // Push the first price on-chain
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint128)",
            asset,
            true,
            redstoneTimestamp
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );
        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        require(success, "Failed to write price");

        // Finalize oracle support
        manager.addAssetPriceFeed(asset, address(adaptor));

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
