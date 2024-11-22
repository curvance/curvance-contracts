// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { DeployConfiguration } from "../utils/DeployConfiguration.sol";
import { OogaBoogaCalldataChecker } from "contracts/calldata-checker/swap-checker/OogaBoogaCalldataChecker.sol";

contract OogaBoogaDeployer is DeployConfiguration {
    address public oogaBoogaBartioRouter =
        0xF6eDCa3C79b4A3DFA82418e278a81604083b999D;
    address public oogaBoogaCalldataChecker;
    function _deployOogaBoogaCallDataChecker() internal {
        address centralRegistry = _getDeployedContract("centralRegistry");
        require(centralRegistry != address(0), "Set the centralRegistry!");

        oogaBoogaCalldataChecker = address(
            new OogaBoogaCalldataChecker(oogaBoogaBartioRouter)
        );

        CentralRegistry(centralRegistry).setExternalCalldataChecker(
            oogaBoogaBartioRouter,
            oogaBoogaCalldataChecker
        );

        console.log("oogaBoogaCalldataChecker: ", oogaBoogaCalldataChecker);

        _saveDeployedContracts(
            "oogaBoogaCalldataChecker",
            oogaBoogaCalldataChecker
        );
    }
}
