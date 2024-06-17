// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { FeeAccumulator } from "contracts/architecture/FeeAccumulator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract FeeAccumulatorDeployer is DeployConfiguration {
    address public feeAccumulator;

    function _deployFeeAccumulator(address centralRegistry) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");

        feeAccumulator = address(
            new FeeAccumulator(ICentralRegistry(centralRegistry))
        );

        console.log("feeAccumulator: ", feeAccumulator);
        _saveDeployedContracts("feeAccumulator", feeAccumulator);
    }
}
