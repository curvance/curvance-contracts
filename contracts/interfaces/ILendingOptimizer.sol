// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Interface for LendingOptimizer, an ERC4626-like vault that
///         allocates deposits across multiple cToken markets.
/// @dev Integrators can call inherited ERC4626 selectors through IERC4626,
///      but preview and max values are multi-market estimates, not strict
///      ERC4626 settlement guarantees. Actual entrypoint results can differ
///      after accrual, liquidity checks, and cToken rounding.
interface ILendingOptimizer {

    /// CONSTANTS ///

    function MAX_FEE_BPS() external view returns (uint256);
    function MAX_MARKETS() external view returns (uint256);

    /// IMMUTABLES ///

    function centralRegistry() external view returns (ICentralRegistry);

    /// STORAGE ///

    function approvedCTokensList(uint256 index) external view returns (address);
    function allocationCaps(address cToken) external view returns (uint256);
    function fee() external view returns (uint256);
    function exchangeRateHighWatermark() external view returns (uint256);
    function mintPaused() external view returns (uint8);

    /// ERC4626 OVERRIDES ///
    /// @dev Declared here so LendingOptimizer can use
    ///      `override(ERC4626, ILendingOptimizer)` for functions it
    ///      customizes beyond the base ERC4626 implementation.

    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// OPTIMIZER-SPECIFIC ///

    function initializeDeposits(address targetMarket) external;
    function addApprovedAsset(address newAsset, uint256 capBps) external;
    function updateCap(address cToken, uint256 newCapBps) external;
    function setFee(uint256 newFeeBps) external;
    function setMintPaused(bool state) external;
    function exchangeRate() external view returns (uint256);
    function exchangeRateUpdated() external returns (uint256);
    function accrueIfNeeded() external;
    function skim() external;
    function skimAvailable() external view returns (uint256);
    function numApprovedMarkets() external view returns (uint256);
    function getApprovedMarkets() external view returns (address[] memory);
}
