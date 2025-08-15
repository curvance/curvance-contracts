// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ILiquidityManager {
    /// @notice Value that indicates whether an account has an active position
    ///         in `cToken`.
    ///         0 or 1 for no; 2 for yes.
    /// @dev Curvance token address => Account address => Active position
    ///      status.
    function accountPositions(
        address cToken,
        address account
    ) external view returns (uint256);
}