// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestBaseFeeAccumulator is TestBaseMarket {
    function setUp() public virtual override {
        _fork(19140000);

        _init();
    }
}
