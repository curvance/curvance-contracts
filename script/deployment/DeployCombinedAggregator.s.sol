// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../utils/DeployScript.sol";

import {CombinedAggregator} from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

contract DeployCombinedAggregator is DeployScript {
    function run(
        address asset,
        address centralRegistry,
        address primaryAggregator,
        address secondaryAggregator,
        uint256 secondaryHeartbeat,
        string memory assetId
    ) external recordEvents returns (address combinedAggregator) {
        IERC20 token = IERC20(asset);

        combinedAggregator = address(
            new CombinedAggregator(
                ICentralRegistry(centralRegistry), primaryAggregator, secondaryAggregator, secondaryHeartbeat, assetId
            )
        );

        emit ContractDeployed(combinedAggregator, string.concat("CombinedAggregator-", token.symbol()));
    }
}
