// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { StartContractsConfig } from "./StartContractsConfig.s.sol";

contract DeployExecuteRedstoneFeeds is
    DeployConfiguration,
    StartContractsConfig
{
    function run() external {
        _deploy("ethereum");
    }

    function run(string memory network) external {
        _deploy(network);
    }

    function _deploy(string memory network) internal {
        _setConfigurationPath(network);
        _setDeploymentPath(network);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: ", deployer);

        vm.startBroadcast(deployerPrivateKey);

        _deploy_redstone_price_feeds(false, true);

        vm.stopBroadcast();
    }
}
