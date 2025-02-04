// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { CentralRegistryDeployer } from "./deployers/CentralRegistryDeployer.s.sol";
import { CveDeployer } from "./deployers/CveDeployer.s.sol";
import { RewardManagerDeployer } from "./deployers/RewardManagerDeployer.s.sol";
import { MessagingHubDeployer } from "./deployers/MessagingHubDeployer.s.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { FeeManagerDeployer } from "./deployers/FeeManagerDeployer.s.sol";
import { VeCveDeployer } from "./deployers/VeCveDeployer.s.sol";
import { VotingHubDeployer } from "./deployers/VotingHubDeployer.s.sol";
import { GaugeManagerDeployer } from "./deployers/GaugeManagerDeployer.s.sol";
import { MarketManagerDeployer } from "./deployers/MarketManagerDeployer.s.sol";
import { OracleManagerDeployer } from "./deployers/OracleManagerDeployer.s.sol";
import { AuxiliaryDataDeployer } from "./deployers/AuxiliaryDataDeployer.s.sol";
import { RedstoneAdaptorDeployer } from "./deployers/RedstoneAdaptorDeployer.s.sol";
import { StartContractsConfig } from "./StartContractsConfig.s.sol";

contract DeployCurvance is
    DeployConfiguration,
    CentralRegistryDeployer,
    CveDeployer,
    RewardManagerDeployer,
    MessagingHubDeployer,
    FeeManagerDeployer,
    VeCveDeployer,
    VotingHubDeployer,
    GaugeManagerDeployer,
    MarketManagerDeployer,
    OracleManagerDeployer,
    AuxiliaryDataDeployer,
    RedstoneAdaptorDeployer,
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

        // address feeToken = _readConfigAddress(".centralRegistry.feeToken");
        address rewardToken = _readConfigAddress(".rewardManager.rewardToken");

        centralRegistry = _getDeployedContract("centralRegistry");
        // address oracleManager = _getDeployedContract("oracleManager");
        // address redstoneAdaptor = _getDeployedContract("redstoneAdaptor");

        _setLockBoostMultiplier(
            _readConfigUint256(".centralRegistry.lockBoostMultiplier")
        );
        _setWormholeCore(_readConfigAddress(".centralRegistry.wormholeCore"));
        _setWormholeRelayer(
            _readConfigAddress(".centralRegistry.wormholeRelayer")
        );
        _setCircleTokenMessenger(
            _readConfigAddress(".centralRegistry.circleTokenMessenger")
        );
        _setMessageTransmitter(
            _readConfigAddress(".centralRegistry.messageTransmitter")
        );
        _setTokenBridge(_readConfigAddress(".centralRegistry.tokenBridge"));
        _addHarvester(_readConfigAddress(".centralRegistry.harvester"));

        // Deploy CVE

        _deployCVE(centralRegistry, _readConfigAddress(".cve.teamAddress"));
        _setCVE(cve);
        // TODO: set some params for cross-chain

        // Deploy Reward Manager

        _deployRewardManager(centralRegistry);
        _setRewardManager(rewardManager);

        // Deploy FeeManager

        _deployFeeManager(centralRegistry);
        _setFeeManager(feeManager);

        // Deploy VeCVE
        _deployVeCve(centralRegistry);
        _setVeCVE(veCve);

        // Deploy GaugeManagerPool
        _deployGaugeManager(centralRegistry);
        _addLockingPermissions(gaugeManager);
        _setGaugeManager(gaugeManager);

        // Deploy MessagingHub
        _deployMessagingHub(centralRegistry);
        _setMessagingHub(messagingHub);
        _addLockingPermissions(messagingHub);

        // Deploy VotingHub
        _deployVotingHub(centralRegistry, 1000);
        _setVotingHub(votingHub);

        //  Deploy Auxiliary Data
        _deployAuxiliaryData(centralRegistry);

        // transfer dao, timelock, emergency council
        // _transferDaoOwnership(
        //     _readConfigAddress(".centralRegistry.daoAddress")
        // );
        // _migrateTimelockConfiguration(
        //     _readConfigAddress(".centralRegistry.timelock")
        // );
        // _transferEmergencyCouncil(
        //     _readConfigAddress(".centralRegistry.emergencyCouncil")
        // );

        // Setup
        _after_deploy_config(network);

        vm.stopBroadcast();
    }
}
