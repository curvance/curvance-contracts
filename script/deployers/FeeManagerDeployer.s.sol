// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { FeeManager } from "contracts/architecture/FeeManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract FeeManagerDeployer is DeployConfiguration {
    address public feeManager;

    function _deployFeeManager(address centralRegistry) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        feeManager = address(
            new FeeManager(ICentralRegistry(centralRegistry))
        );

        console.log("feeManager: ", feeManager);
        _saveDeployedContracts("feeManager", feeManager);
    }
}
