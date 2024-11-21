// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CVE } from "contracts/token/RemoteCVE.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseRemoteCVE is TestBaseMarket {
    CVE public remoteCVE;

    function _deployCVE() internal override initMainVariables {
        remoteCVE = new CVE(ICentralRegistry(address(centralRegistry)));
        centralRegistry.setCVE(address(remoteCVE));
    }
}
