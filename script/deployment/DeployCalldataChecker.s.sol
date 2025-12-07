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
            KuruCalldataChecker checker = new KuruCalldataChecker(checkerSelection.kuruRouter, 0x62eE1b8D1EFdF8f73c78dB87b888406b194e266a, cr.daoAddress());
            cr.setExternalCalldataChecker(checkerSelection.kuruRouter, address(checker));
        }
    }
}
