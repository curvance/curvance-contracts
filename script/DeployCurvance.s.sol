// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/console.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { CentralRegistryDeployer } from "./deployers/CentralRegistryDeployer.s.sol";
import { CveDeployer } from "./deployers/CveDeployer.s.sol";
import { RewardManagerDeployer } from "./deployers/RewardManagerDeployer.s.sol";
import { ProtocolMessagingHubDeployer } from "./deployers/ProtocolMessagingHubDeployer.s.sol";
import { FeeAccumulatorDeployer } from "./deployers/FeeAccumulatorDeployer.s.sol";
import { VeCveDeployer } from "./deployers/VeCveDeployer.s.sol";
import { GaugePoolDeployer } from "./deployers/GaugePoolDeployer.s.sol";
import { MarketManagerDeployer } from "./deployers/MarketManagerDeployer.s.sol";
import { ComplexZapperDeployer } from "./deployers/ComplexZapperDeployer.s.sol";
import { PositionFoldingDeployer } from "./deployers/PositionFoldingDeployer.s.sol";
import { OracleRouterDeployer } from "./deployers/OracleRouterDeployer.s.sol";
import { AuxiliaryDataDeployer } from "./deployers/AuxiliaryDataDeployer.s.sol";
import { StartContractsConfig } from "./StartContractsConfig.s.sol";

contract DeployCurvance is
    DeployConfiguration,
    CentralRegistryDeployer,
    CveDeployer,
    RewardManagerDeployer,
    ProtocolMessagingHubDeployer,
    FeeAccumulatorDeployer,
    VeCveDeployer,
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

        address feeToken = _readConfigAddress(".centralRegistry.feeToken");
        address rewardToken = _readConfigAddress(".rewardManager.rewardToken");
        if (_is_testnet(network)) {
            _deployMockTokens();
            feeToken = _getDeployedContract("USDC");
            rewardToken = _getDeployedContract("USDC");
        }

        // Deploy CentralRegistry
        _deployCentralRegistry(
            deployer,
            deployer,
            deployer,
            _readConfigUint256(".centralRegistry.genesisEpoch"),
            _readConfigAddress(".centralRegistry.sequencer"),
            feeToken
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
        _setTokenBridge(_readConfigAddress(".centralRegistry.tokenBridge"));
        _addHarvester(_readConfigAddress(".centralRegistry.harvester"));

        // Deploy CVE

        _deployCVE(centralRegistry, _readConfigAddress(".cve.teamAddress"));
        _setCVE(cve);
        // TODO: set some params for cross-chain

        // Deploy Reward Manager

        _deployRewardManager(centralRegistry, rewardToken);
        _setRewardManager(rewardManager);

        // Deploy FeeAccumulator

        _deployFeeAccumulator(centralRegistry);
        _setFeeAccumulator(feeAccumulator);

        // Deploy VeCVE
        _deployVeCve(centralRegistry);
        _setVeCVE(veCve);

        // Deploy ProtocolMessagingHub
        _deployProtocolMessagingHub(centralRegistry);
        _setProtocolMessagingHub(protocolMessagingHub);

        // Deploy GaugePool

        _deployGaugePool(centralRegistry);
        _addLockingPermissions(gaugePool);

        // Deploy MarketManager

        _deployMarketManager(centralRegistry, gaugePool);
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

        // Deploy PositionFolding

        _deployPositionFolding(centralRegistry, marketManager);

        _deployOracleRouter(
            centralRegistry,
            _readConfigAddress(".oracleRouter.chainlinkEthUsd")
        );

        _setOracleRouter(oracleRouter);

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
