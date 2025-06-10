// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { DeployConfiguration } from "../utils/DeployConfiguration.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract SimplePositionManagerDeployer is DeployConfiguration {
    address public simplePositionManager;

    function _deploySimplePositionManager(
        address marketManager,
        string memory marketName,
        address wrappedNative
    ) internal {
        address centralRegistry = _getDeployedContract("centralRegistry");
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(marketManager != address(0), "Set the marketManager!");
        require(bytes(marketName).length > 0, "Set the marketName!");
        require(wrappedNative != address(0), "Set the wrappedNative!");

        simplePositionManager = address(
            new SimplePositionManager(
                ICentralRegistry(centralRegistry),
                marketManager,
                wrappedNative
            )
        );

        MarketManagerIsolated(marketManager).addPositionManager(
            simplePositionManager
        );

        console.log(
            string.concat(marketName, "-simplePositionManager: "),
            simplePositionManager
        );

        _saveDeployedContracts(
            string.concat(marketName, "-simplePositionManager"),
            simplePositionManager
        );
    }
}
