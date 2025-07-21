// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

contract AddCrosschainSupport is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        address centralRegistry,
        address wormholeCore,
        address wormholeRelayer,
        address cctpTokenMessenger,
        address cctpMessageTransmitter
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        CentralRegistry registry = CentralRegistry(centralRegistry);
        registry.setCrosschainCore(wormholeCore);
        registry.setCrosschainRelayer(wormholeRelayer);
        registry.setTokenMessenger(cctpTokenMessenger);
        registry.setMessageTransmitter(cctpMessageTransmitter);

        ICentralRegistry icr = ICentralRegistry(centralRegistry);
        MessagingHub messagingHub = new MessagingHub(icr);
        registry.setMessagingHub(address(messagingHub));
        registry.addLockingPermissions(address(messagingHub));
        emit ContractDeployed(address(messagingHub), "MessagingHub");

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
