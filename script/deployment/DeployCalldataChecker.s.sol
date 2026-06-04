// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { KyberSwapChecker } from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import { PendleZapperMinimalCalldataChecker } from "contracts/calldata-checker/swap-checker/PendleZapperMinimalCalldataChecker.sol";
import { PendleZapperMinimal } from "contracts/plugins/market/PendleZapperMinimal.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract DeployCalldataChecker is DeployScript {
    struct AvailableCheckers {
        address router;
        address pendleZapperMinimal;
        address pendleRouter;
    }

    error DeployCalldataChecker__InvalidKyberRouter();
    error DeployCalldataChecker__InvalidPendleZapperMinimal();
    error DeployCalldataChecker__InvalidPendleRouter();

    address KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    address[] EXECUTORS = [
        0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0, // current
        0x4a16958D2041044C67c8F33017a75693Cc58F7CC, // new
        0x8F10B468b06c6FD214B65F87778827F7D113f996 // current API route executor
    ];

    function run(
        address registry,
        AvailableCheckers calldata checkerSelection
    ) external recordEvents {
        CentralRegistry cr = CentralRegistry(registry);

        if (checkerSelection.router != address(0)) {
            if (checkerSelection.router != KYBER_ROUTER) {
                revert DeployCalldataChecker__InvalidKyberRouter();
            }

            KyberSwapChecker checker = new KyberSwapChecker(
                checkerSelection.router,
                EXECUTORS,
                address(cr)
            );
            cr.setExternalCalldataChecker(
                checkerSelection.router,
                address(checker)
            );
        }

        if (checkerSelection.pendleZapperMinimal != address(0)) {
            PendleZapperMinimal pendleZapperMinimal = PendleZapperMinimal(
                payable(checkerSelection.pendleZapperMinimal)
            );
            try pendleZapperMinimal.ptOnly() returns (bool ptOnly) {
                if (!ptOnly) {
                    revert DeployCalldataChecker__InvalidPendleZapperMinimal();
                }
            } catch {
                revert DeployCalldataChecker__InvalidPendleZapperMinimal();
            }
            if (checkerSelection.pendleRouter != PENDLE_ROUTER) {
                revert DeployCalldataChecker__InvalidPendleRouter();
            }

            PendleZapperMinimalCalldataChecker checker = new PendleZapperMinimalCalldataChecker(
                    checkerSelection.pendleZapperMinimal,
                    checkerSelection.pendleRouter
                );
            cr.setExternalCalldataChecker(
                checkerSelection.pendleZapperMinimal,
                address(checker)
            );
        }
    }
}
