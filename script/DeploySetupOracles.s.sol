// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { CentralRegistryDeployer } from "./deployers/CentralRegistryDeployer.s.sol";
import { OracleRouterDeployer } from "./deployers/OracleRouterDeployer.s.sol";
import { StartContractsConfig } from "./StartContractsConfig.s.sol";
import { RedstoneAdaptorDeployer } from "./deployers/RedstoneAdaptorDeployer.s.sol";

import { console } from "forge-std/console.sol";

contract DeploySetupOracles is
    DeployConfiguration,
    StartContractsConfig,
    CentralRegistryDeployer,
    OracleRouterDeployer,
    RedstoneAdaptorDeployer
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

        address feeToken = _readConfigAddress(".centralRegistry.feeToken");
        uint256 genesisEpoch = _readConfigUint256(
            ".centralRegistry.genesisEpoch"
        );
        if (_is_testnet(network)) {
            genesisEpoch = block.timestamp;
        }

        // Deploy CentralRegistry
        _deployCentralRegistry(
            deployer,
            deployer,
            deployer,
            genesisEpoch,
            _readConfigAddress(".centralRegistry.sequencer"),
            feeToken
        );

        // Deploy OracleRouter
        _deployOracleRouter(centralRegistry);
        _setOracleRouter(oracleRouter);

        // Deploy RedstoneAdaptor
        _deployRedstoneAdaptor(centralRegistry);
        _deploy_redstone_price_feeds(true, false);

        vm.stopBroadcast();
    }
}
