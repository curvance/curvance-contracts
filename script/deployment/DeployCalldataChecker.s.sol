// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { KyberSwapChecker } from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract DeployCalldataChecker is DeployScript {
    struct AvailableCheckers {
        address router;
    }

    address KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    address[] EXECUTORS = [
        0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0, // current
        0x4a16958D2041044C67c8F33017a75693Cc58F7CC // new
    ];


    function run(address registry, AvailableCheckers calldata checkerSelection) external recordEvents {
        CentralRegistry cr = CentralRegistry(registry);

        if(checkerSelection.router != address(0)) {
            KyberSwapChecker checker = new KyberSwapChecker(
                checkerSelection.router, 
                EXECUTORS, 
                address(cr)
            );
            cr.setExternalCalldataChecker(checkerSelection.router, address(checker));
        }
    }
}
