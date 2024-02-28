// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestBaseProtocolMessagingHub is TestBaseMarket {
    function setUp() public virtual override {
        _fork(19140000);

        _init();
    }
}
