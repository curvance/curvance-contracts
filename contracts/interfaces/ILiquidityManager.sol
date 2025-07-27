// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILiquidityManager {
    /// @notice Curvance token data including listing status,
    ///         token characterists, account position data.
    /// @dev Curvance token Address => TokenData struct.
    function tokenData(address cToken) external view returns (
        bool isListed,
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqIncBase,
        uint256 liqIncCurve,
        uint256 liqIncMin,
        uint256 liqIncMax,
        uint256 closeFactorBase,
        uint256 closeFactorCurve,
        uint256 closeFactorMin,
        uint256 closeFactorMax
    );

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