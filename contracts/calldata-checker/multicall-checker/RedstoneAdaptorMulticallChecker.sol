// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseMulticallChecker } from "contracts/calldata-checker/multicall-checker/BaseMulticallChecker.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract RedstoneAdaptorMulticallChecker is BaseMulticallChecker {
    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) BaseMulticallChecker(cr) {}

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
        // Validate `target` is actually a Redstone Core adaptor. This will
        // also fail if `target` does not properly implement `IOracleAdaptor`.
        _checkIsApprovedAdaptor(target, 1);

        if (_getFuncSigHash(data) != RedstoneCoreAdaptor.writePrice.selector) {
            revert MulticallChecker__InvalidFuncSig();
        }
    }
}