// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CVE } from "contracts/token/RemoteCVE.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseRemoteCVE is TestBaseMarket {
    CVE public remoteCVE;

    function setUp() public virtual override {
        super.setUp();

        remoteCVE = new CVE(ICentralRegistry(address(centralRegistry)));
    }
}
