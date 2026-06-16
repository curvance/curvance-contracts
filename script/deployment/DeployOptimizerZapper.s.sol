// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../utils/DeployScript.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {OptimizerZapper} from "contracts/plugins/market/OptimizerZapper.sol";

contract DeployOptimizerZapper is DeployScript {
    function run(address centralRegistryAddress, address wrappedNative) external recordEvents {
        OptimizerZapper optimizerZapper = new OptimizerZapper(ICentralRegistry(centralRegistryAddress), wrappedNative);

        emit ContractDeployed(address(optimizerZapper), "zappers.optimizerZapper");
    }
}
