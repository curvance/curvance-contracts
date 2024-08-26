// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { VeCVE } from "contracts/token/VeCVE.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract VeCveDeployer is DeployConfiguration {
    address public veCve;

    function _deployVeCve(address centralRegistry) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        veCve = address(new VeCVE(ICentralRegistry(centralRegistry)));

        console.log("veCve: ", veCve);
        _saveDeployedContracts("veCve", veCve);
    }
}
