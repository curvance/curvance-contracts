// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { CVE } from "contracts/token/CVE.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract CveDeployer is DeployConfiguration {
    address public cve;

    function _deployCVE(address centralRegistry, address team) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(team != address(0), "Set the contributor address!");

        cve = address(new CVE(ICentralRegistry(centralRegistry), team));

        console.log("cve: ", cve);
        _saveDeployedContracts("cve", cve);
    }
}
