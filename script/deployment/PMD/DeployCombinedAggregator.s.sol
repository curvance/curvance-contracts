// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DeployCombinedAggregator is DeployScript {
    struct PriceGuard {
        bool enabled;
        bool inUSD;
        uint256 timestampSubtract;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    function run(
        address asset,
        // ====== CombinedAggregator Parameters ======
        address centralRegistry,
        address primaryAggregator,
        address secondaryAggregator,
        uint256 secondaryHeartbeat,
        string memory assetId,
        PriceGuard memory combinedGuardConfig,
        // ====== ChainlinkAdaptor Parameters ======
        address adaptorAddress,
        uint256 heartbeat
    ) external recordEvents {
        IERC20 token = IERC20(asset);

        // ====== Deploy and configure CombinedAggregator ======
        address agg = address(
            new CombinedAggregator(
                ICentralRegistry(address(centralRegistry)),
                primaryAggregator,
                secondaryAggregator,
                secondaryHeartbeat,
                assetId
            )
        );
        emit ContractDeployed(agg, string.concat("CombinedAggregator-", token.symbol()));
        
    }
}
