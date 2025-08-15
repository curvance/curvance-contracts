// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { ProtocolReader } from "contracts/views/ProtocolReader.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DeployProtocolReader is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(address registry) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        // TODO: Update this to ProtocolReader instead of ProtocolReader2 when 2 is done and moves to the normal file
        ICentralRegistry icr = ICentralRegistry(registry);
        address newContract = address(new ProtocolReader(icr));
        emit ContractDeployed(newContract, "ProtocolReader");

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
