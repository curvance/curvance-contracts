// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";

contract DeployLendingOptimizer is DeployScript {
    function run(
        string memory name,
        address depositAsset,
        address centralRegistryAddress,
        address[] memory ctokens,
        uint256[] memory caps,
        uint256 feeInBps,
        bool deployReader,
        OptimizerReader.CollateralGuardConfig[] memory guardTypes,
        uint256 stalenessMultiplier
    ) external recordEvents {
        IERC20 asset = IERC20(depositAsset);
        ICentralRegistry icr = ICentralRegistry(centralRegistryAddress);
        LendingOptimizer optimizer = new LendingOptimizer(asset, icr, ctokens, caps, feeInBps);

        emit ContractDeployed(
            address(optimizer),
            string.concat("Optimizers.", name)
        );

        if(deployReader) {
            OptimizerReader reader = new OptimizerReader(icr, guardTypes, stalenessMultiplier);
            emit ContractDeployed(
                address(reader),
                string.concat("OptimizerReader")
            );
        }
    }
}
