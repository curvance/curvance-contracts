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

    /// @notice Exposes _optimalTarget for deposit target selection.
    function optimalDepositTarget(uint256 assets) external view returns (uint256) {
        return _optimalTarget(assets, true);
    }

    /// @notice Exposes _optimalTarget for withdrawal target selection.
    function optimalWithdrawalTarget(uint256 assets) external view returns (uint256) {
        return _optimalTarget(assets, false);
    }
}
