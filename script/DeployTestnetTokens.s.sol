// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { StartContractsConfig } from "./StartContractsConfig.s.sol";

contract DeployTestnetTokens is DeployConfiguration, StartContractsConfig {
    function run() external {
        _deploy("ethereum");
    }

    function run(string memory network) external {
        _deploy(network);
    }

    function _deploy(string memory network) internal {
        _setConfigurationPath(network);
        _setDeploymentPath(network);
        _clearDeployedContracts();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: ", deployer);

        vm.startBroadcast(deployerPrivateKey);

        if (_is_testnet(network)) {
            _deployMockTokens();
        }

        vm.stopBroadcast();
    }
}
