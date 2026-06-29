// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../utils/DeployScript.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    PendlePTAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/PendlePTAggregator.sol";

contract DeployPendlePTAggregator is DeployScript {
    function run(
        address pt,
        address asset,
        address aggregator,
        uint256 discountOneYearBPS,
        string memory assetId
    ) external recordEvents {
        address pendlePTAggregator = address(
            new PendlePTAggregator(
                pt, asset, aggregator, discountOneYearBPS, assetId
            )
        );

        emit ContractDeployed(
            pendlePTAggregator,
            string.concat("PendlePTAggregator-", IERC20(pt).symbol())
        );
    }
}
