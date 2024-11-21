// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract MessagingHubDeployer is DeployConfiguration {
    address public messagingHub;

    function _deployMessagingHub(address centralRegistry) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        messagingHub = address(
            new MessagingHub(ICentralRegistry(centralRegistry))
        );

        console.log("messagingHub: ", messagingHub);
        _saveDeployedContracts("messagingHub", messagingHub);
    }
}
