// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IMulticallChecker } from "contracts/interfaces/IMulticallChecker.sol";
import { BaseCallDataChecker } from "contracts/calldata-checker/BaseCallDataChecker.sol";

abstract contract BaseMulticallChecker is
    IMulticallChecker,
    BaseCallDataChecker
{
    /// ERRORS ///
    error MulticallChecker__TargetError();
    error MulticallChecker__InvalidFuncSig();
    error MulticallChecker__InvalidCalldata();

    /// STORAGE ///
    address public centralRegistry;

    /// CONSTRUCTOR ///

    constructor(address _centralRegistry) {
        centralRegistry = _centralRegistry;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks attached calldata to validate that the target contract
    ///         is an approved oracle adaptor and the proper function selector
    ///         is being called.
    /// @dev MUST be overridden in every calldata checkers contract's
    ///      implementation.
    function checkCalldata(
        address caller,
        address target,
        bytes memory data
    ) external virtual override;
}
