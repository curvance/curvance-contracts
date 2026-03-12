// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title LendingOptimizerHarness
/// @notice Exposes internal functions and state for testing.
contract LendingOptimizerHarness is LendingOptimizer {

    constructor(
        IERC20 asset_,
        ICentralRegistry _centralRegistry,
        address[] memory _approvedCTokens,
        uint256[] memory _allocationCapsBps,
        uint256 _feeBps
    ) LendingOptimizer(
        asset_,
        _centralRegistry,
        _approvedCTokens,
        _allocationCapsBps,
        _feeBps
    ) {}

    /// @notice Returns the indexed total assets.
    function exposed_totalAssetsIndexed() external view returns (uint256) {
        return _totalAssets;
    }

    /// @notice Exposes _accrueIfNeeded() for direct testing.
    function exposed_accrueIfNeeded() external {
        _accrueIfNeeded();
    }

    /// @notice Exposes _accrueMarkets() for direct testing.
    function exposed_accrueMarkets() external returns (uint256) {
        return _accrueMarkets();
    }

    /// @notice Returns shares using the original ERC4626 previewDeposit
    ///         (without the -2 adjustment) for comparison testing.
    function oldPreviewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Exposes _supplyQueueTarget for deposit target selection.
    function supplyQueueTarget() external view returns (address) {
        return _supplyQueueTarget();
    }

    /// @notice Exposes _accruedState() for diagnostic testing.
    function exposed_accruedState() external view returns (uint256 accruedTa, uint256 accruedSupply) {
        return _accruedState();
    }

    /// @notice Exposes _projectedMarketAssets() for diagnostic testing.
    function exposed_projectedMarketAssets(address cToken) external view returns (uint256) {
        return _projectedMarketAssets(cToken);
    }

    /// @notice Exposes _availableLiquidity() for diagnostic testing.
    function exposed_availableLiquidity() external view returns (uint256) {
        return _availableLiquidity();
    }

    /// @notice Test-only: deposits into a specific market for setup purposes.
    /// @dev Bypasses optimal routing to allow tests to create specific
    ///      allocation distributions across markets.
    function depositToMarket(
        uint256 assets,
        address receiver,
        address targetMarket
    ) external nonReentrant returns (uint256 shares) {
        _checkMintPaused();
        _accrueIfNeeded();
        shares = _deposit(assets, receiver, targetMarket);
    }
}
