// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { ETokenDeployer } from "./deployers/eToken/ETokenDeployer.s.sol";

contract DeployEToken is Script, DeployConfiguration, ETokenDeployer {
    using stdJson for string;

    function run(string memory name) external {
        _deploy("ethereum", name);
    }

    function run(string memory network, string memory name) external {
        _deploy(network, name);
    }

    function _deploy(string memory network, string memory name) internal {
        _setConfigurationPath(network);
        _setDeploymentPath(network);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: ", deployer);

        string memory configurationJson = vm.readFile(configurationPath);

        vm.startBroadcast(deployerPrivateKey);

        _deployEToken(
            string.concat("E-", name),
            abi.decode(
                configurationJson.parseRaw(
                    string.concat(".markets.dTokens.", name)
                ),
                (ETokenDeployer.ETokenParam)
            )
        );

        vm.stopBroadcast();
    }
}
