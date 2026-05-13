// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";

contract DeployOptimizerReader is DeployScript {
    address centralRegistryAddress = 0x1310f352f1389969Ece6741671c4B919523912fF;
    uint256 stalenessMultiplier = 11000;


    function run(
    ) external recordEvents {
        OptimizerReader reader = new OptimizerReader(
            ICentralRegistry(centralRegistryAddress),
            stalenessMultiplier
        );

        emit ContractDeployed(address(reader), "OptimizerReader");
    }
}
