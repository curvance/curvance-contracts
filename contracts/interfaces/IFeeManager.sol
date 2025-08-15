// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IFeeManager {
    /// @notice Updates to new messaging hub and moves fee token approval
    function notifyUpdatedMessagingHub() external;

    /// @notice Sends collected fee tokens ex compounding bot stipend to the
    ///         Messaging Hub.
    /// @dev Only callable by the Messaging Hub.
    ///      Does not fail if fees collected equal 0.
    /// @param amount The amount of token to transfer.
    /// @return The amount of transferred fee tokens to the Messaging Hub.
    function pullFees(uint256 amount) external returns (uint256);
}
