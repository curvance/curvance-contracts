// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";

contract TestBaseDynamicIRM is TestBaseMarketIsolated {
    DynamicIRM public IRM;

    function setUp() public virtual override {
        super.setUp();
        IRM = IRMs[block.chainid][_USDC_ADDRESS];
    }
}
