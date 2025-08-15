// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { RedstoneAdaptorMulticallChecker } from "contracts/calldata-checker/multicall-checker/RedstoneAdaptorMulticallChecker.sol";

contract DeployBase is Script {
    struct Config {
        address daoAddress;
        address emergencyCouncil;
        uint256 genesisEpoch;
        address sequencer;
        address feeToken;
    }

    struct Adaptors {
        bool redstonePull;
        bool redstonePush;
        bool chainlink;
    }

    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        Config memory config,
        address harvester,
        Adaptors calldata adaptors
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        // Deploy CentralRegistry
        CentralRegistry centralRegistry = new CentralRegistry(
            config.daoAddress,
            config.emergencyCouncil,
            config.genesisEpoch,
            config.sequencer,
            config.feeToken
        );
        emit ContractDeployed(address(centralRegistry), "CentralRegistry");
        ICentralRegistry icr = ICentralRegistry(address(centralRegistry));
        centralRegistry.addHarvestPermissions(harvester);

        // Deploy Oracle Manager
        OracleManager oracleManager = new OracleManager(icr);
        centralRegistry.setOracleManager(address(oracleManager));
        emit ContractDeployed(address(oracleManager), "OracleManager");

        if (adaptors.chainlink) {
            address chainlinkAdaptor = address(new ChainlinkAdaptor(icr));
            oracleManager.addApprovedAdaptor(chainlinkAdaptor);
            emit ContractDeployed(chainlinkAdaptor, "ChainlinkAdaptor");
        }

        if (adaptors.redstonePush) {
            address classicRedstoneAdaptor = address(
                new RedstoneClassicAdaptor(icr)
            );
            oracleManager.addApprovedAdaptor(classicRedstoneAdaptor);
            emit ContractDeployed(
                classicRedstoneAdaptor,
                "RedstoneClassicAdaptor"
            );
        }

        if (adaptors.redstonePull) {
            // Deploy Redstone Adaptor
            address[] memory redstoneSigners = new address[](4);
            redstoneSigners[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
            redstoneSigners[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
            redstoneSigners[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
            redstoneSigners[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
            address redstoneCoreAdaptor = address(
                new RedstoneCoreAdaptor(icr, redstoneSigners, 3, "ETH")
            );
            emit ContractDeployed(redstoneCoreAdaptor, "RedstoneCoreAdaptor");
            address multicallChecker = address(
                new RedstoneAdaptorMulticallChecker(icr)
            );
            emit ContractDeployed(
                multicallChecker,
                "RedstoneAdaptorMulticallChecker"
            );
            centralRegistry.setMulticallChecker(
                redstoneCoreAdaptor,
                multicallChecker
            );
            oracleManager.addApprovedAdaptor(redstoneCoreAdaptor);
        }

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
