// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Interface for LendingOptimizer, an ERC4626-like vault that
///         allocates deposits across multiple cToken markets.
/// @dev Integrators can call inherited ERC4626 selectors through IERC4626,
///      but preview and max values are multi-market estimates, not strict
///      ERC4626 settlement guarantees. Actual entrypoint results can differ
///      after accrual, liquidity checks, and cToken rounding.
///      Approved markets must not have a direct or transitive collateral or
///      valuation dependency back to the optimizer. The implementation's
///      runtime admission check rejects only the direct sibling case;
///      operators must verify the complete dependency closure before
///      initialization and after market or oracle configuration changes.
interface ILendingOptimizer {

    /// CONSTANTS ///

    function MAX_FEE_BPS() external view returns (uint256);
    function MAX_MARKETS() external view returns (uint256);

    /// IMMUTABLES ///

    function centralRegistry() external view returns (ICentralRegistry);

    /// STORAGE ///

    function approvedCTokensList(uint256 index) external view returns (address);
    /// @dev A managed-rebalance bound, not a continuously enforced exposure
    ///      limit. Yield and donations can cause drift; pro-rata flows need
    ///      not restore an over-cap allocation.
    function allocationCaps(address cToken) external view returns (uint256);
    function fee() external view returns (uint256);
    function exchangeRateHighWatermark() external view returns (uint256);
    function mintPaused() external view returns (uint8);

    /// ERC4626 OVERRIDES ///
    /// @dev Declared here so LendingOptimizer can use
    ///      `override(ERC4626, ILendingOptimizer)` for functions it
    ///      customizes beyond the base ERC4626 implementation.

    function asset() external view returns (address);
    /// @dev Cached until an optimizer path invokes accrual or explicitly
    ///      resynchronizes accounting.
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// OPTIMIZER-SPECIFIC ///

    /// @dev Verify all approved markets' dependency closures before calling.
    function initializeDeposits(address targetMarket) external;

    /// @dev Performs only the implementation's direct runtime checks.
    ///      Operators must preflight and read back the complete dependency
    ///      closure.
    function addApprovedAsset(address newAsset, uint256 capBps) external;
    function updateCap(address cToken, uint256 newCapBps) external;
    function setFee(uint256 newFeeBps) external;
    function setMintPaused(bool state) external;
    /// @dev Cached view. Do not use as credit authority without fresh accrual.
    function exchangeRate() external view returns (uint256);
    function exchangeRateUpdated() external returns (uint256);
    function accrueIfNeeded() external;
    function skim() external;
    function skimAvailable() external view returns (uint256);
    function numApprovedMarkets() external view returns (uint256);
    function getApprovedMarkets() external view returns (address[] memory);
}
