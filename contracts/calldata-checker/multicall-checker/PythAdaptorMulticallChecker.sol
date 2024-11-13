// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";
import { OracleManager, IOracleAdaptor } from "contracts/oracles/OracleManager.sol";

import { BaseMulticallChecker } from "./BaseMulticallChecker.sol";

contract PythAdaptorMulticallChecker is BaseMulticallChecker {
    /// CONSTRUCTOR ///

    constructor(
        address _centralRegistry
    ) BaseMulticallChecker(_centralRegistry) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks attached calldata to validate that the target contract
    ///         is an approved oracle adaptor and the proper function selector
    ///         is being called.
    /// @param caller Address of the user that will be updating the Pyth
    ///               Adaptor price.
    /// @param target Target contract address that will be called with `data`
    ///               calldata.
    /// @param data Calldata attached to target call, contains function
    ///             signature being called which will be checked.
    function checkCalldata(
        address caller,
        address target,
        bytes memory data
    ) external view override {
        OracleManager oracleManager = OracleManager(
            ICentralRegistry(centralRegistry).oracleManager()
        );

        // Validate that target contract is actually approved inside the
        // oracle manager.
        if (!oracleManager.isApprovedAdaptor(target)) {
            revert MulticallChecker__TargetError();
        }

        // Validate that target contract is actually a Pyth oracle adaptor.
        // This will also fail if the target does not properly follow protocol
        // adaptor design which includes an adaptor type function.
        if (IOracleAdaptor(target).adaptorType() != 2) {
            revert MulticallChecker__TargetError();
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
                revert MulticallChecker__InvalidCalldata();
            }
        } else {
            revert MulticallChecker__InvalidFuncSig();
        }
    }
}
