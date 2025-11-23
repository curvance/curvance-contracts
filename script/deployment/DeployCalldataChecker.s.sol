// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { KuruCalldataChecker } from "contracts/calldata-checker/swap-checker/KuruCalldataChecker.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract DeployCalldataChecker is DeployScript {
    struct AvailableCheckers {
        address kuruRouter;
    }

    function run(address registry, AvailableCheckers calldata checkerSelection) external recordEvents {
        CentralRegistry cr = CentralRegistry(registry);
        
        if(checkerSelection.kuruRouter != address(0)) {
            KuruCalldataChecker checker = new KuruCalldataChecker(checkerSelection.kuruRouter, 0xb3e6778480b2E488385E8205eA05E20060B813cb, cr.daoAddress());
            cr.setExternalCalldataChecker(checkerSelection.kuruRouter, address(checker));
        }
    }
}