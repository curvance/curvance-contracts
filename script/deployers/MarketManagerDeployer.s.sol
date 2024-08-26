// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract MarketManagerDeployer is DeployConfiguration {
    address public marketManager;

    function _deployMarketManager(
        address centralRegistry
    ) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        marketManager = address(
            new MarketManager(ICentralRegistry(centralRegistry))
        );

        console.log("marketManager: ", marketManager);
        _saveDeployedContracts("marketManager", marketManager);
    }
}
