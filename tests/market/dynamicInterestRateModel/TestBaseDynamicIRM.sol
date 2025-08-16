// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { DynamicIRM } from "contracts/market/DynamicIRM.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestBaseDynamicIRM is TestBaseMarketIsolated {
    DynamicIRM public IRM;

    function setUp() public virtual override {
        super.setUp();
        IRM = IRMs[block.chainid][_USDC_ADDRESS];
    }
}
