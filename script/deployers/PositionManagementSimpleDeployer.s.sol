// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { DeployConfiguration } from "../utils/DeployConfiguration.sol";
import { PositionManagementSimple } from "contracts/market/position-management/PositionManagementSimple.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract PositionManagementSimpleDeployer is DeployConfiguration {
    address public positionManagementSimple;

    function _deployPositionManagementSimple(
        address marketManager,
        string memory marketName,
        address wrappedNative
    ) internal {
        address centralRegistry = _getDeployedContract("centralRegistry");
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(marketManager != address(0), "Set the marketManager!");
        require(bytes(marketName).length > 0, "Set the marketName!");
        require(wrappedNative != address(0), "Set the wrappedNative!");

        positionManagementSimple = address(
            new PositionManagementSimple(
                ICentralRegistry(centralRegistry),
                marketManager,
                wrappedNative
            )
        );

        MarketManagerIsolated(marketManager).addPositionManagement(
            positionManagementSimple
        );

        console.log(
            string.concat(marketName, "-positionManagementSimple: "),
            positionManagementSimple
        );

        _saveDeployedContracts(
            string.concat(marketName, "-positionManagementSimple"),
            positionManagementSimple
        );
    }
}
