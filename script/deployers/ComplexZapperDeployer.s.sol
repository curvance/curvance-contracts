// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { ComplexZapper } from "contracts/plugins/market/ComplexZapper.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract ComplexZapperDeployer is DeployConfiguration {
    address public complexZapper;

    function _deployComplexZapper(
        address centralRegistry,
        address weth,
        string memory marketName
    ) internal returns (address) {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(weth != address(0), "Set the weth!");

        complexZapper = address(
            new ComplexZapper(ICentralRegistry(centralRegistry), weth)
        );

        console.log(
            string.concat(marketName, "-complexZapper: "),
            complexZapper
        );
        _saveDeployedContracts(
            string.concat(marketName, "-complexZapper"),
            complexZapper
        );
    }
}
