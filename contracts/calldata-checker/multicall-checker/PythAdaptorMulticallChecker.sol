// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { BaseMulticallChecker } from "contracts/calldata-checker/multicall-checker/BaseMulticallChecker.sol";
import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract PythAdaptorMulticallChecker is BaseMulticallChecker {
    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) BaseMulticallChecker(cr) {}

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
        // Validate `target` is actually a Pyth oracle adaptor. This will also
        // fail if `target` does not properly implement `IOracleAdaptor`.
        _checkIsApprovedAdaptor(target, 4);

        if (
            _getFuncSigHash(data) == PythAdaptor
                .updateFeedsFromUniversalBalance.selector
        ) {
            (, address user) = abi.decode(
                _getFuncParams(data),
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