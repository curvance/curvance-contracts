// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract GaugeManagerDeployer is DeployConfiguration {
    address public gaugeManager;

    function _deployGaugeManager(address centralRegistry) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        gaugeManager = address(new GaugeManager(ICentralRegistry(centralRegistry)));

        console.log("gaugeManager: ", gaugeManager);
        _saveDeployedContracts("gaugeManager", gaugeManager);
    }
}
