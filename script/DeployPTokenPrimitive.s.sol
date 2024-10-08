// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { PTokenDeployer } from "./deployers/pToken/PTokenDeployer.s.sol";

contract DeployPTokenPrimitive is Script, DeployConfiguration, PTokenDeployer {
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

        _deployPToken(
            string.concat("P-", name),
            abi.decode(
                configurationJson.parseRaw(
                    string.concat(".markets.pTokens.", name)
                ),
                (PTokenDeployer.PTokenParam)
            )
        );

        vm.stopBroadcast();
    }
}
