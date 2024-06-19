// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract ProtocolMessagingHubDeployer is DeployConfiguration {
    address public protocolMessagingHub;

    function _deployProtocolMessagingHub(address centralRegistry) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        protocolMessagingHub = address(
            new ProtocolMessagingHub(ICentralRegistry(centralRegistry))
        );

        console.log("protocolMessagingHub: ", protocolMessagingHub);
        _saveDeployedContracts("protocolMessagingHub", protocolMessagingHub);
    }
}
