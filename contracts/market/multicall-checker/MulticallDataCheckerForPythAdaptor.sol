// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";

import { MulticallDataCheckerBase } from "./MulticallDataCheckerBase.sol";

contract MulticallDataCheckerForPythAdaptor is MulticallDataCheckerBase {
    /// CONSTRUCTOR ///

    constructor(
        address _centralRegistry
    ) MulticallDataCheckerBase(_centralRegistry) {}

    /// EXTERNAL FUNCTIONS ///

    function checkCallData(
        address caller,
        address target,
        bytes memory data
    ) external view override {
        OracleRouter oracleRouter = OracleRouter(
            ICentralRegistry(centralRegistry).oracleRouter()
        );

        if (!oracleRouter.isApprovedAdaptor(target)) {
            revert MulticallDataChecker__TargetError();
        }

        bytes4 functionSig = getFuncSigHash(data);
        if (
            functionSig == PythAdaptor.updateFeedsFromUniversalBalance.selector
        ) {
            (, address user) = abi.decode(
                getFuncParams(data),
                (bytes[], address)
            );
            if (caller != user) {
                revert MulticallDataChecker__InvalidCallData();
            }
        } else {
            revert MulticallDataChecker__InvalidFuncSig();
        }
    }
}
