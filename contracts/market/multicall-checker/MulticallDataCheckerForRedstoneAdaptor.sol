// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";

import { MulticallDataCheckerBase } from "./MulticallDataCheckerBase.sol";

contract MulticallDataCheckerForRedstoneAdaptor is MulticallDataCheckerBase {
    /// CONSTRUCTOR ///

    constructor(
        address _centralRegistry
    ) MulticallDataCheckerBase(_centralRegistry) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks attached calldata to validate that the target contract
    ///         is an approved oracle adaptor and the proper function selector
    ///         is being called.
    /// @param target Target contract address that will be called with `data`
    ///               calldata.
    /// @param data Calldata attached to target call, contains function
    ///             signature being called which will be checked.
    function checkCallData(
        address,
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
        if (functionSig != RedstoneCoreAdaptor.writePrice.selector) {
            revert MulticallDataChecker__InvalidFuncSig();
        }
    }
}
