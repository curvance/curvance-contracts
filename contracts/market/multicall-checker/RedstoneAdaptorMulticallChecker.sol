// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

import { BaseMulticallChecker } from "./BaseMulticallChecker.sol";

contract RedstoneAdaptorMulticallChecker is BaseMulticallChecker {
    /// CONSTRUCTOR ///

    constructor(
        address _centralRegistry
    ) BaseMulticallChecker(_centralRegistry) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks attached calldata to validate that the target contract
    ///         is an approved oracle adaptor and the proper function selector
    ///         is being called.
    /// @param target Target contract address that will be called with `data`
    ///               calldata.
    /// @param data Calldata attached to target call, contains function
    ///             signature being called which will be checked.
    function checkCalldata(
        address,
        address target,
        bytes memory data
    ) external view override {
        OracleManager oracleManager = OracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        );

        if (!oracleManager.isApprovedAdaptor(target)) {
            revert MulticallChecker__TargetError();
        }

        bytes4 functionSig = getFuncSigHash(data);
        if (functionSig != RedstoneCoreAdaptor.writePrice.selector) {
            revert MulticallChecker__InvalidFuncSig();
        }
    }
}
