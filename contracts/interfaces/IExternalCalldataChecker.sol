// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

interface IExternalCalldataChecker {
    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on swap to inspect and validate calldata safety.
    /// @param swapAction Swap action instructions including both direct
    ///                   parameters and decodeable calldata.
    /// @param expectedRecipient Address who will receive proceeds of
    ///                          `swapAction`.
    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address expectedRecipient
    ) external;
}
