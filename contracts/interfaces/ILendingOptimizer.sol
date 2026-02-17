// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ILendingOptimizer {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function getApprovedMarkets() external view returns (address[] memory);
    function exchangeRate() external view returns (uint256);
    function fee() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}
