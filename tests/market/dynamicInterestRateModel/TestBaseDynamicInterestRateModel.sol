// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";

contract TestBaseDynamicInterestRateModel is TestBaseMarket {
    DynamicInterestRateModel public interestRateModel;

    function setUp() public virtual override {
        super.setUp();
        interestRateModel = interestRateModels[block.chainid][_USDC_ADDRESS];
    }
}
