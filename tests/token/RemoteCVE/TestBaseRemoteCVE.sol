// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CVE } from "contracts/token/RemoteCVE.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseRemoteCVE is TestBaseMarketIsolated {
    CVE public remoteCVE;

    function _deployCVE() internal override initMainVariables {
        remoteCVE = new CVE(ICentralRegistry(address(centralRegistry)));
        centralRegistry.setCVE(address(remoteCVE));
    }
}
