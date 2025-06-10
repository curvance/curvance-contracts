// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { AuxiliaryData } from "contracts/indexing/AuxiliaryData.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract AuxiliaryDataDeployer is DeployConfiguration {
    address public auxiliaryData;

    function _deployAuxiliaryData(address centralRegistry) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        auxiliaryData = address(
            new AuxiliaryData(ICentralRegistry(centralRegistry))
        );

        console.log("auxiliaryData: ", auxiliaryData);
        _saveDeployedContracts("auxiliaryData", auxiliaryData);
    }
}
