// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BasePTokenWithGauge, SafeTransferLib } from "contracts/market/token/withGauge/BasePTokenWithGauge.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev Built to support assets that do not generate rewards in external,
///      claimable tokens. Meaning SimplePToken is built for assets such as:
///      WETH, LSTs, Principal Tokens, Stablecoins, Yield-bearing stablecoins,
///      etc.
///
///      All token deposits are recorded in the protocol "Gauge Manager"
///      facilitating the distribution of native tokens both liquid and
///      locked to users based on their contributions to the protocol over
///      time.
contract SimplePToken is BasePTokenWithGauge {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) BasePTokenWithGauge(centralRegistry_, asset_, marketManager_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Starts a pToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    ///      NOTE: ONLY CALLED ONCE DURING TOKEN LISTING BY DAO AUTHORIZED
    ///            ADDRESS FROM THE MARKET MANAGER.
    /// @param by The account initializing the pToken market.
    /// @return Returns with true when successful.
    function startMarket(
        address by
    ) external override nonReentrant returns (bool) {
        _startMarket(by);
        return true;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns total assets invariant and any pending rewards for
    ///         depositors.
    function _calculateTotalAssetsWithRewards() internal view override returns (
        uint256,
        uint256
    ) {
        return (_totalAssets, 0);
    }

    /// @notice Updates asset values for a pending deposit request.
    /// @param assets The amount of the underlying asset to deposit.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    function _updateAssetsForDeposit(
        uint256 assets,
        uint256 ta,
        uint256 /* pending */
    ) internal override {
        // Document addition of `assets` to `ta` due to deposit.
        unchecked {
            _totalAssets = ta + assets;
        }
    }

    /// @notice Updates asset values for a pending withdrawal request.
    /// @param assets The amount of the underlying asset to withdraw.
    /// @param ta The current total number of assets for assets to shares
    ///           conversion.
    function _updateAssetsForWithdrawal(
        uint256 assets,
        uint256 ta,
        uint256 /* pending */
    ) internal override {
        // Document removal of `assets` from `ta` due to withdrawal.
        _totalAssets = ta - assets;
    }
}
