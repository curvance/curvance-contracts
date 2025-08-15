// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";

contract DeployExample is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run() external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        // Do deploy stuff here
        // When you want to log a new contract emit ContractDeployed
        // Or any other event you may want to track with the contract-deployer repo

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
