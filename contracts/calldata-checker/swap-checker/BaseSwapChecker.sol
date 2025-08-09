// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCalldataChecker } from "contracts/calldata-checker/BaseCalldataChecker.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IExternalCalldataChecker } from "contracts/interfaces/IExternalCalldataChecker.sol";

/// @title BaseSwapChecker
/// @notice A base contract for validating external swap operations and DEX interactions
/// @dev This abstract contract serves as the foundation for protocol-specific swap
///      validation. It inherits from IExternalCalldataChecker and BaseCalldataChecker to provide:
///      
///      1. A standardized interface for all swap checkers
///      2. Access to core calldata examination utilities
///      3. A reference to the target swap contract for validation
///      
///      The primary purpose of swap checkers is to secure token swap operations by:
///      - Verifying the target contract matches the expected DEX router
///      - Validating swap recipients match the expected address
///      - Confirming input/output tokens match what's declared in the swap instructions
///      - Ensuring input amounts match the declared values
///      - Checking that function signatures are valid for the target DEX
///      
///      This security layer prevents:
///      - Token theft through unauthorized recipients
///      - Swapping incorrect tokens or amounts
///      - Calling unauthorized functions or contracts
///      - Other malicious manipulation of swap parameters
///      
///      Specific implementations like OneInchCalldataChecker, OdosCalldataChecker,
///      PendleZapperCalldataChecker, etc. extend this base contract to provide
///      DEX-specific validation logic.
///      
///      The SwapperLib uses these checkers when processing swaps to ensure
///      calldata integrity before execution.
///
abstract contract BaseSwapChecker is
    IExternalCalldataChecker,
    BaseCalldataChecker
{
    /// ERRORS ///

    error CalldataChecker__TargetError();
    error CalldataChecker__RecipientError();
    error CalldataChecker__InputTokenError();
    error CalldataChecker__InputAmountError();
    error CalldataChecker__OutputTokenError();
    error CalldataChecker__InvalidFuncSig();

    /// STORAGE ///
    
    /// @notice The address of the target swap contract
    address public target;

    /// CONSTRUCTOR ///

    constructor(address _target) {
        target = _target;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Overridden in child calldata checker contracts,
    ///         used to inspect and validate calldata safety.
    /// @param recipient Address who will receive proceeds of `swapAction`.
    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address recipient
    ) external view virtual override;
}
