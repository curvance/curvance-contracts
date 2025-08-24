// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { AddChainLinkSupport } from './AddChainLinkSupport.s.sol';
import { AddRedstoneSupport } from './AddRedstoneSupport.s.sol';

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { VaultZapper } from "contracts/plugins/market/VaultZapper.sol";
import { NativeVaultZapper } from "contracts/plugins/market/NativeVaultZapper.sol";

contract DeployBase is DeployScript  {
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

    AddRedstoneSupport internal redstoneSupport;
    AddChainLinkSupport internal chainlinkSupport;

    constructor() {
        redstoneSupport = new AddRedstoneSupport();
        chainlinkSupport = new AddChainLinkSupport();
    }

    function run(
        Config memory config,
        address harvester,
        Adaptors calldata adaptors,
        address wrappedNative
    ) external recordEvents {
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

        OracleManager oracleManager = new OracleManager(icr);
        centralRegistry.setOracleManager(address(oracleManager));
        emit ContractDeployed(address(oracleManager), "OracleManager");

        _deployAdaptors(icr, centralRegistry, adaptors, oracleManager);
        _deployZappers(icr, wrappedNative);
    }

    function _deployAdaptors(
        ICentralRegistry icr,
        CentralRegistry registry,
        Adaptors memory adaptors, 
        OracleManager oracleManager
    ) internal {
        if (adaptors.chainlink) {
            chainlinkSupport.deployChainlinkAdaptor(icr, oracleManager);
        }

        if (adaptors.redstonePush) {
            redstoneSupport.deployRedstoneClassicAdaptor(icr, oracleManager);
        }

        if (adaptors.redstonePull) {
            redstoneSupport.deployRedstoneCoreAdaptor(registry, icr, oracleManager);
        }
    }

    function _deployZappers(ICentralRegistry icr, address wrappedNative) internal {
        NativeVaultZapper nativeVaultZapper = new NativeVaultZapper(icr, wrappedNative);
        emit ContractDeployed(
            address(nativeVaultZapper),
            string.concat("zappers.nativeVaultZapper")
        );

        VaultZapper vaultZapper = new VaultZapper(icr, wrappedNative);
        emit ContractDeployed(
            address(vaultZapper),
            string.concat("zappers.vaultZapper")
        );
        
        SimpleZapper simpleZapper = new SimpleZapper(icr, wrappedNative);
        emit ContractDeployed(
            address(simpleZapper),
            string.concat("zappers.simpleZapper")
        );
    }
}
