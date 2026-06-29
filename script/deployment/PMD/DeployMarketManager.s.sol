// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../../utils/DeployScript.sol";

import {MarketManagerIsolated} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

contract DeployMarketManager is DeployScript {
    function run(address centralRegistry, string memory marketName, uint256 minLoanSize, bool isCorrelated)
        external
        recordEvents
    {
        MarketManagerIsolated market =
            new MarketManagerIsolated(ICentralRegistry(centralRegistry), minLoanSize, isCorrelated);

        emit ContractDeployed(address(market), string.concat("markets.", marketName, ".address"));
    }
}
