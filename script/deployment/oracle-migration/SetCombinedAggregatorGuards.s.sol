// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { ICombinedAggregator } from "contracts/interfaces/ICombinedAggregator.sol";

contract SetCombinedAggregatorGuards is DeployScript {
    struct PriceGuard {
        bool enabled;
        uint256 timestampStart;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    struct CombinedAggregatorGuard {
        address aggregator;
        PriceGuard guard;
    }

    function run(CombinedAggregatorGuard[] calldata guards) external recordEvents {
        for (uint256 i; i < guards.length; ++i) {
            CombinedAggregatorGuard calldata item = guards[i];
            if (!item.guard.enabled) {
                continue;
            }

            ICombinedAggregator(item.aggregator).setGuardedPriceConfig(
                item.guard.timestampStart,
                item.guard.ips,
                item.guard.basePrice,
                item.guard.minPrice
            );
        }
    }
}