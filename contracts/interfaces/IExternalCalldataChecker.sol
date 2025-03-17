// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

interface IExternalCalldataChecker {
    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on Zap/swap to inspect and validate calldata safety.
    /// @param swapData Zap/swap instruction data including both direct
    ///                 parameters and decodeable calldata.
    /// @param expectedRecipient User who will receive results of Zap/swap.
    function checkCalldata(
        SwapperLib.Swap memory swapData,
        address expectedRecipient
    ) external;
}
