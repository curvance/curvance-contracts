// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract CentralRegistryDeployer is DeployConfiguration {
    address public centralRegistry;

    function _deployCentralRegistry(
        address daoAddress,
        address timelock,
        address emergencyCouncil,
        uint256 genesisEpoch,
        address sequencer,
        address feeToken
    ) internal {
        require(daoAddress != address(0), "Set the daoAddress!");
        require(timelock != address(0), "Set the timelock!");
        require(emergencyCouncil != address(0), "Set the emergencyCouncil!");
        require(feeToken != address(0), "Set the feeToken!");

        centralRegistry = address(
            new CentralRegistry(
                daoAddress,
                timelock,
                emergencyCouncil,
                genesisEpoch,
                sequencer,
                feeToken
            )
        );

        console.log("centralRegistry: ", centralRegistry);
        _saveDeployedContracts("centralRegistry", centralRegistry);
    }

    function _setLockBoostMultiplier(uint256 lockBoostMultiplier) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        CentralRegistry(centralRegistry).setLockBoostMultiplier(
            lockBoostMultiplier
        );
        console.log(
            "centralRegistry.setLockBoostMultiplier: ",
            lockBoostMultiplier
        );
    }

    function _addHarvester(address harvester) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(harvester != address(0), "Set the harvester!");

        CentralRegistry(centralRegistry).addHarvester(harvester);
        console.log("centralRegistry.addHarvester: ", harvester);
    }

    function _setCVE(address cve) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(cve != address(0), "Set the cve!");

        CentralRegistry(centralRegistry).setCVE(cve);
        console.log("centralRegistry.setCVE: ", cve);
    }

    function _setRewardManager(address rewardManager) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(rewardManager != address(0), "Set the rewardManager!");

        CentralRegistry(centralRegistry).setRewardManager(rewardManager);
        console.log("centralRegistry.setRewardManager: ", rewardManager);
    }

    function _setMessagingHub(address messagingHub) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(messagingHub != address(0), "Set the messagingHub!");

        CentralRegistry(centralRegistry).setMessagingHub(messagingHub);
        console.log("centralRegistry.setMessagingHub: ", messagingHub);
    }

    function _setFeeManager(address feeManager) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(feeManager != address(0), "Set the feeManager!");

        CentralRegistry(centralRegistry).setFeeManager(feeManager);
        console.log("centralRegistry.setFeeManager: ", feeManager);
    }

    function _setVeCVE(address veCve) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(veCve != address(0), "Set the veCve!");

        CentralRegistry(centralRegistry).setVeCVE(veCve);
        console.log("centralRegistry.setVeCVE: ", veCve);
    }

    function _setWormholeCore(address wormholeCore) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        CentralRegistry(centralRegistry).setWormholeCore(wormholeCore);
        console.log("centralRegistry.setWormholeCore: ", wormholeCore);
    }

    function _setWormholeRelayer(address wormholeRelayer) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        CentralRegistry(centralRegistry).setWormholeRelayer(wormholeRelayer);
        console.log("centralRegistry.setWormholeRelayer: ", wormholeRelayer);
    }

    function _setCircleTokenMessenger(address circleTokenMessenger) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        CentralRegistry(centralRegistry).setCircleTokenMessenger(
            circleTokenMessenger
        );
        console.log(
            "centralRegistry.setCircleTokenMessenger: ",
            circleTokenMessenger
        );
    }

    function _setMessageTransmitter(address messageTransmitter) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        CentralRegistry(centralRegistry).setMessageTransmitter(
            messageTransmitter
        );
        console.log(
            "centralRegistry.setMessageTransmitter: ",
            messageTransmitter
        );
    }

    function _setTokenBridge(address tokenBridge) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        CentralRegistry(centralRegistry).setTokenBridge(tokenBridge);
        console.log("centralRegistry.setTokenBridge: ", tokenBridge);
    }

    function _setVoteBoostMultiplier(uint256 voteBoostMultiplier) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        CentralRegistry(centralRegistry).setVoteBoostMultiplier(
            voteBoostMultiplier
        );
        console.log(
            "centralRegistry.setVoteBoostMultiplier: ",
            voteBoostMultiplier
        );
    }

    function _setOracleManager(address oracleManager) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(oracleManager != address(0), "Set the oracleManager!");

        CentralRegistry(centralRegistry).setOracleManager(oracleManager);
        console.log("centralRegistry._setOracleManager: ", oracleManager);
    }

    function _addLockingPermissions(address newApprovedAddress) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(
            newApprovedAddress != address(0),
            "Set the newApprovedAddress!"
        );

        CentralRegistry(centralRegistry).addLockingPermissions(
            newApprovedAddress
        );
        console.log(
            "centralRegistry.addLockingPermissions: ",
            newApprovedAddress
        );
    }

    function _addMarketManager(
        address marketManager,
        uint256 marketInterestFactor
    ) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(marketManager != address(0), "Set the marketManager!");

        CentralRegistry(centralRegistry).addMarketManager(
            marketManager,
            marketInterestFactor
        );
        console.log("centralRegistry.addMarketManager: ", marketManager);
    }

    function _transferDaoOwnership(address daoAddress) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(daoAddress != address(0), "Set the daoAddress!");

        CentralRegistry(centralRegistry).transferDaoOwnership(daoAddress);
        console.log("centralRegistry.transferDaoOwnership: ", daoAddress);
    }

    function _migrateTimelockConfiguration(address timelock) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(timelock != address(0), "Set the timelock!");

        CentralRegistry(centralRegistry).migrateTimelockConfiguration(
            timelock
        );
        console.log(
            "centralRegistry.migrateTimelockConfiguration: ",
            timelock
        );
    }

    function _transferEmergencyCouncil(address emergencyCouncil) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(emergencyCouncil != address(0), "Set the emergencyCouncil!");

        CentralRegistry(centralRegistry).transferEmergencyCouncil(
            emergencyCouncil
        );
        console.log(
            "centralRegistry.transferEmergencyCouncil: ",
            emergencyCouncil
        );
    }
}
