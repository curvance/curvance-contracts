// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IMulticallChecker } from "contracts/interfaces/IMulticallChecker.sol";
import { BaseCalldataChecker } from "contracts/calldata-checker/BaseCalldataChecker.sol";

/// @title BaseMulticallChecker
/// @notice A base contract for validating multicall operations related to oracle price updates
/// @dev This abstract contract serves as the foundation for protocol-specific oracle 
///      validation. It inherits from IMulticallChecker and BaseCalldataChecker to provide:
///      
///      1. A standardized interface for all multicall checkers
///      2. Access to core calldata examination utilities
///      3. A reference to the central registry for protocol-wide verification
///      
///      The primary purpose of multicall checkers is to secure oracle price updates by:
///      - Verifying the target contract is an approved oracle adaptor
///      - Validating the function signature being called is appropriate
///      - Ensuring all parameters match expected values
///      
///      This security layer prevents:
///      - Malicious price manipulations through unauthorized oracle adaptors
///      - Calls to unintended functions within oracle adaptors
///      - Improperly formatted calldata
///      
///      Specific implementations like RedstoneAdaptorMulticallChecker and 
///      PythAdaptorMulticallChecker extend this base contract to provide 
///      oracle-specific validation logic.
///      
///      The Multicall library uses these checkers when processing price updates
///      before liquidity-dependent actions.
///
abstract contract BaseMulticallChecker is
    IMulticallChecker,
    BaseCalldataChecker
{  
    /// ERRORS ///
    error MulticallChecker__TargetError();
    error MulticallChecker__InvalidFuncSig();
    error MulticallChecker__InvalidCalldata();

    /// STORAGE ///
    /// @notice The address of the central registry
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
