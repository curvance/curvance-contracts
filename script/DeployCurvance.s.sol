// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { CentralRegistryDeployer } from "./deployers/CentralRegistryDeployer.s.sol";
import { CveDeployer } from "./deployers/CveDeployer.s.sol";
import { RewardManagerDeployer } from "./deployers/RewardManagerDeployer.s.sol";
import { MessagingHubDeployer } from "./deployers/MessagingHubDeployer.s.sol";
import { FeeManagerDeployer } from "./deployers/FeeManagerDeployer.s.sol";
import { VeCveDeployer } from "./deployers/VeCveDeployer.s.sol";
import { GaugeManagerDeployer } from "./deployers/GaugeManagerDeployer.s.sol";
import { MarketManagerDeployer } from "./deployers/MarketManagerDeployer.s.sol";
import { ComplexZapperDeployer } from "./deployers/ComplexZapperDeployer.s.sol";
import { OracleManagerDeployer } from "./deployers/OracleManagerDeployer.s.sol";
import { AuxiliaryDataDeployer } from "./deployers/AuxiliaryDataDeployer.s.sol";

contract DeployCurvance is
    DeployConfiguration,
    CentralRegistryDeployer,
    CveDeployer,
    RewardManagerDeployer,
    MessagingHubDeployer,
    FeeManagerDeployer,
    VeCveDeployer,
    GaugeManagerDeployer,
    MarketManagerDeployer,
    ComplexZapperDeployer,
    OracleManagerDeployer,
    AuxiliaryDataDeployer
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

        // Deploy CentralRegistry

        _deployCentralRegistry(
            deployer,
            deployer,
            deployer,
            _readConfigUint256(".centralRegistry.genesisEpoch"),
            _readConfigAddress(".centralRegistry.sequencer"),
            _readConfigAddress(".centralRegistry.feeToken")
        );
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

        _deployRewardManager(
            centralRegistry,
            _readConfigAddress(".rewardManager.rewardToken")
        );
        _setRewardManager(rewardManager);

        // Deploy MessagingHub

        _deployMessagingHub(centralRegistry);
        _setMessagingHub(messagingHub);

        // Deploy FeeManager

        _deployFeeManager(centralRegistry);
        _setFeeManager(feeManager);

        // Deploy VeCVE

        _deployVeCve(centralRegistry);
        _setVeCVE(veCve);

        // Deploy GaugeManagerPool

        _deployGaugeManager(centralRegistry);
        _addLockingPermissions(gaugeManager);

        // Deploy MarketManager

        _deployMarketManager(centralRegistry);
        _addMarketManager(
            marketManager,
            _readConfigUint256(".marketManager.marketInterestFactor")
        );

        // Deploy ComplexZapper

        _deployComplexZapper(
            centralRegistry,
            marketManager,
            _readConfigAddress(".zapper.weth")
        );

        _deployOracleManager(
            centralRegistry,
            _readConfigAddress(".oracleManager.chainlinkEthUsd")
        );

        _setOracleManager(oracleManager);

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

        vm.stopBroadcast();
    }
}
