// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract SimpleZapperDeployer is DeployConfiguration {
    address public simpleZapper;

    function _deploySimpleZapper(
        address centralRegistry,
        address marketManager,
        address weth,
        string memory marketName
    ) internal returns (address) {
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

        console.log(
            string.concat(marketName, "-simpleZapper: "),
            simpleZapper
        );
        _saveDeployedContracts(
            string.concat(marketName, "-simpleZapper"),
            simpleZapper
        );
    }
}
