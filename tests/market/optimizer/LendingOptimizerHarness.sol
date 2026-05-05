// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
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

    /// @notice Exposes _calculateDepositProRata() for boundary tests.
    function exposed_calculateDepositProRata(
        uint256 assets,
        bool conversionRoundtrip
    ) external view returns (uint256[] memory) {
        return _calculateDepositProRata(assets, conversionRoundtrip);
    }

    /// @notice Test-only: corrupts local cap state to exercise invariant guards.
    function exposed_setAllocationCap(address cToken, uint256 cap) external {
        allocationCaps[cToken] = cap;
    }

    /// @notice Returns shares using the original ERC4626 previewDeposit
    ///         (without the -2 adjustment) for comparison testing.
    function oldPreviewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Test-only: deposits into a specific market for setup purposes.
    /// @dev Bypasses pro-rata routing to allow tests to create specific
    ///      allocation distributions across markets.
    function depositToMarket(
        uint256 assets,
        address receiver,
        address targetMarket
    ) external nonReentrant returns (uint256 shares) {
        _checkMintPaused();
        _accrueIfNeeded();

        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);
        uint256 trackedAssets = _depositToMarket(targetMarket, assets);

        shares = convertToShares(trackedAssets);
        if (shares == 0) revert LendingOptimizer__InvalidParameter();

        _totalAssets += trackedAssets;
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }
}
