// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { SimpleZapper } from "contracts/market/zapper/SimpleZapper.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract SimpleZapperDeployer is DeployConfiguration {
    function _deploySimpleZapper(
        address centralRegistry,
        address marketManager,
        address weth
    ) internal returns (address) {
        address simpleZapper;

        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(marketManager != address(0), "Set the marketManager!");
        require(weth != address(0), "Set the weth!");

        simpleZapper = address(
            new SimpleZapper(
                ICentralRegistry(centralRegistry),
                marketManager,
                weth
            )
        );

        console.log("Created simple zapper: ", simpleZapper);
        return simpleZapper;
    }
}
