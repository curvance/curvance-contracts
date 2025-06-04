// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILiquidityManager {
    /// @notice Market token data including listing status,
    ///         token characterists, account position data.
    /// @dev Market Token Address => MarketToken struct.
    function tokenData(address mToken) external view returns (
        bool isListed,
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqBaseIncentive,
        uint256 liqCurve,
        uint256 liqMinIncentive,
        uint256 liqMaxIncentive,
        uint256 minEffectiveCloseFactor,
        uint256 maxEffectiveCloseFactor,
        uint256 baseCFactor,
        uint256 cFactorCurve
    );

}