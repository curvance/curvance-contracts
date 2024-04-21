// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";

import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";

contract StartContractsConfig is Script, DeployConfiguration {
    using stdJson for string;

    function run(string memory name) external {
        _update("ethereum", name);
    }

    function run(string memory network, string memory name) external {
        _update(network, name);
    }

    function _update(string memory network, string memory name) internal {
        _setConfigurationPath(network);
        _setDeploymentPath(network);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: ", deployer);

        vm.startBroadcast(deployerPrivateKey);

        _startRewardManager();

        vm.stopBroadcast();
    }

    function _startRewardManager() internal {
        address centralRegistry = _getDeployedContract("centralRegistry");
        console.log("centralRegistry =", centralRegistry);
        address payable rewardManager = payable(_getDeployedContract("rewardManager"));
        console.log("rewardManager =", rewardManager);
        
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(RewardManager(rewardManager).rewardManagerStarted() != 2, "Reward Manager already started!");
        require(CentralRegistry(centralRegistry).veCVE() != address(0), "Set veCVE!");

        RewardManager(rewardManager).startRewardManager();
        console.log("startRewardManager");
    }
}
