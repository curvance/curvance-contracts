// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { VotingHub } from "contracts/architecture/VotingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract VotingHubDeployer is DeployConfiguration {
    address public votingHub;

    function _deployVotingHub(
        address centralRegistry,
        uint256 baseEmissionsPerEpoch
    ) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        votingHub = address(
            new VotingHub(
                ICentralRegistry(centralRegistry),
                baseEmissionsPerEpoch
            )
        );

        console.log("votingHub: ", votingHub);
        _saveDeployedContracts("votingHub", votingHub);
    }
}
