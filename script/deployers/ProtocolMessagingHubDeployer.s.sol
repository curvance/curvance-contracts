// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";

import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract ProtocolMessagingHubDeployer is DeployConfiguration {
    address protocolMessagingHub;

    function _deployProtocolMessagingHub(address centralRegistry, address wormhole) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(wormhole != address(0), "Set Wormhole Core Contract!");

        protocolMessagingHub = address(
            new ProtocolMessagingHub(
                ICentralRegistry(centralRegistry),
                wormhole
            )
        );

        console.log("protocolMessagingHub: ", protocolMessagingHub);
        _saveDeployedContracts("protocolMessagingHub", protocolMessagingHub);
    }
}
