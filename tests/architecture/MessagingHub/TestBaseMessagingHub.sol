// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestBaseMessagingHub is TestBaseMarketIsolated {
    function setUp() public virtual override {
        _fork(19140000);

        _init();
    }
}
