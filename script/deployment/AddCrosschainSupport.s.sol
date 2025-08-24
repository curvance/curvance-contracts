// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

contract AddCrosschainSupport is DeployScript {
    function run(
        address centralRegistry,
        address wormholeCore,
        address wormholeRelayer,
        address cctpTokenMessenger,
        address cctpMessageTransmitter
    ) external recordEvents {
        CentralRegistry registry = CentralRegistry(centralRegistry);
        registry.setCrosschainCore(wormholeCore);
        registry.setCrosschainRelayer(wormholeRelayer);
        registry.setTokenMessager(cctpTokenMessenger);
        registry.setMessageTransmitter(cctpMessageTransmitter);

        ICentralRegistry icr = ICentralRegistry(centralRegistry);
        MessagingHub messagingHub = new MessagingHub(icr);
        registry.setMessagingHub(address(messagingHub));
        registry.addLockingPermissions(address(messagingHub));
        emit ContractDeployed(address(messagingHub), "MessagingHub");
    }
}
