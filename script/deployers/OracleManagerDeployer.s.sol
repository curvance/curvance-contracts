// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract OracleManagerDeployer is DeployConfiguration {
    address public oracleManager;

    function _deployOracleManager(
        address centralRegistry,
        address /* ethUsdFeed */
    ) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        oracleManager = address(
            new OracleManager(ICentralRegistry(centralRegistry))
        );

        console.log("oracleManager: ", oracleManager);
        _saveDeployedContracts("oracleManager", oracleManager);
    }
}
