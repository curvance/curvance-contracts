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
    function allocationCaps(address cToken) external view returns (uint256);
    function numApprovedMarkets() external view returns (uint256);
    function deposit(
        uint256 assets,
        address receiver,
        address targetMarket
    ) external returns (uint256 shares);
}
