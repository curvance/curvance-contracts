// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";

import { Faucet } from "contracts/testnet/Faucet.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
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
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        bool is_testnet,
        Config memory config,
        address harvester
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        // Deploy Faucet
        if (is_testnet) {
            Faucet faucet = new Faucet();
            emit ContractDeployed(address(faucet), "Faucet");
        }

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

        // Deploy Redstone Adaptor
        address[] memory redstoneSigners = new address[](4);
        redstoneSigners[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
        redstoneSigners[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
        redstoneSigners[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
        redstoneSigners[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
        RedstoneCoreAdaptor adaptor = new RedstoneCoreAdaptor(
            icr,
            redstoneSigners,
            3,
            "ETH"
        );
        emit ContractDeployed(address(adaptor), "RedstoneCoreAdaptor");
        RedstoneAdaptorMulticallChecker multicallChecker = new RedstoneAdaptorMulticallChecker(
                address(icr)
            );
        emit ContractDeployed(
            address(multicallChecker),
            "RedstoneAdaptorMulticallChecker"
        );
        centralRegistry.setMulticallChecker(
            address(adaptor),
            address(multicallChecker)
        );
        oracleManager.addApprovedAdaptor(address(adaptor));

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
