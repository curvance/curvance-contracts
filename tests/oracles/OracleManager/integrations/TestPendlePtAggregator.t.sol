// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { PendlePTAggregator } from "contracts/oracles/adaptors/wrappedAggregators/PendlePTAggregator.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestPendlePtAggregator is TestBaseOracleManager {
    PendlePTAggregator public aggregator;

    function setUp() public override {
    }

}