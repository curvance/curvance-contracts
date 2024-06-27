// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract RewardManagerDeployer is DeployConfiguration {
    address public rewardManager;

    function _deployRewardManager(
        address centralRegistry,
        address rewardToken
    ) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(rewardToken != address(0), "Set the rewardToken!");

        rewardManager = address(
            new RewardManager(ICentralRegistry(centralRegistry), rewardToken)
        );

        console.log("rewardManager: ", rewardManager);
        _saveDeployedContracts("rewardManager", rewardManager);
    }
}
