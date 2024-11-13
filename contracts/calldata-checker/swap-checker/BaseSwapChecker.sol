// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IExternalCalldataChecker } from "contracts/interfaces/IExternalCalldataChecker.sol";
import { BaseCallDataChecker } from "contracts/calldata-checker/BaseCallDataChecker.sol";

abstract contract BaseSwapChecker is
    IExternalCalldataChecker,
    BaseCallDataChecker
{
    /// ERRORS ///
    error CalldataChecker__TargetError();
    error CalldataChecker__RecipientError();
    error CalldataChecker__InputTokenError();
    error CalldataChecker__InputAmountError();
    error CalldataChecker__OutputTokenError();
    error CalldataChecker__InvalidFuncSig();

    /// STORAGE ///
    address public target;

    /// CONSTRUCTOR ///

    constructor(address _target) {
        target = _target;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Overridden in child Calldata checker contracts,
    ///         used to inspect and validate calldata safety.
    function checkCalldata(
        SwapperLib.Swap memory _swapData,
        address _recipient
    ) external view virtual override;
}
