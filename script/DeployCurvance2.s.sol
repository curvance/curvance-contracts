// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { CentralRegistryDeployer } from "./deployers/CentralRegistryDeployer.s.sol";
import { CveDeployer } from "./deployers/CveDeployer.s.sol";
import { RewardManagerDeployer } from "./deployers/RewardManagerDeployer.s.sol";
import { MessagingHubDeployer } from "./deployers/MessagingHubDeployer.s.sol";
import { FeeAccumulatorDeployer } from "./deployers/FeeAccumulatorDeployer.s.sol";
import { VeCveDeployer } from "./deployers/VeCveDeployer.s.sol";
import { VotingHubDeployer } from "./deployers/VotingHubDeployer.s.sol";
import { GaugePoolDeployer } from "./deployers/GaugePoolDeployer.s.sol";
import { MarketManagerDeployer } from "./deployers/MarketManagerDeployer.s.sol";
import { ComplexZapperDeployer } from "./deployers/ComplexZapperDeployer.s.sol";
import { PositionFoldingDeployer } from "./deployers/PositionFoldingDeployer.s.sol";
import { OracleRouterDeployer } from "./deployers/OracleRouterDeployer.s.sol";
import { AuxiliaryDataDeployer } from "./deployers/AuxiliaryDataDeployer.s.sol";
import { StartContractsConfig } from "./StartContractsConfig.s.sol";

contract DeployCurvance2 is
    DeployConfiguration,
    CentralRegistryDeployer,
    CveDeployer,
    RewardManagerDeployer,
    MessagingHubDeployer,
    FeeAccumulatorDeployer,
    VeCveDeployer,
    VotingHubDeployer,
    GaugePoolDeployer,
    MarketManagerDeployer,
    ComplexZapperDeployer,
    PositionFoldingDeployer,
    OracleRouterDeployer,
    AuxiliaryDataDeployer,
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

        // Setup
        _deploy_redstone_price_feeds(network);

        vm.stopBroadcast();
    }
}
