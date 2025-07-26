// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";

contract SimplePositionManager is BasePositionManager {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_
    )
        BasePositionManager(
            centralRegistry_,
            marketManager_,
            wrappedNative_
        )
    {}

    /// @notice Callback function on borrowing tokens from an borrowableCToken
    ///         contract providing instant liquidity in the borrowableCToken
    ///         underlying which is then swapped into the underlying of a
    ///         cToken that a user is currently putting up as collateral
    ///         against the borrowableCToken debt position, creating a
    ///         leveraged spot position.
    /// @param leverageAction Instructions for a leverage action containing:
    ///                       borrowableCToken Address of `borrowableCToken`
    ///                                        that will be borrowed from and
    ///                                        assets swapped.
    ///                       borrowAssets The amount borrowed from
    ///                                    `borrowableCToken`, in assets.
    ///                       cToken Curvance token assets that borrowed funds
    ///                              will be swapped into.
    ///                       swapAction Swap action instructions converting
    ///                                  debt asset into collateral asset to
    ///                                  facilitate leveraging.
    ///                       auxData Optional auxiliary data for execution of a
    ///                               a leverage action.
    function _swapDebtAssetToCollateralAsset(
        LeverageAction memory leverageAction,
        address /* receiver */
    ) internal virtual override {
        SwapperLib.Swap memory swapAction = leverageAction.swapAction;
        address debtAsset = leverageAction.borrowableCToken.asset();
        address collateralAsset = leverageAction.cToken.asset();

        if (debtAsset == collateralAsset) {
            return;
        }

        if (swapAction.call.length == 0) {
            revert BasePositionManager__InvalidParam();
        }

        if (
            swapAction.target == address(0) ||
            swapAction.inputToken != debtAsset ||
            swapAction.outputToken != collateralAsset ||
            swapAction.inputAmount != leverageAction.borrowAssets
        ) {
            revert BasePositionManager__InvalidParam();
        }

        // Swap debt asset to collateral asset.
        SwapperLib._swapSafe(centralRegistry, swapAction);
    }

    /// @notice Callback function on redemption of tokens from a cToken vault
    ///         providing instant liquidity in the cToken underlying which is
    ///         then swapped into the underlying of an borrowableCToken that a
    ///         user is currently borrowing from, partially or fully closing a
    ///         leveraged spot position.
    /// @param deleverageAction Struct containing information on a deleverage
    ///                         action to execute. Containing values:
    ///                         1. Address of the cToken whose asset will be
    ///                            routed into debt asset to repay outstanding
    ///                            debt.
    ///                         2. The amount of `cToken` that will
    ///                            be deleveraged.
    ///                         3. Address of borrowableCToken that will have
    ///                            its outstanding debt repaid.
    ///                         4. Swap action instructions converting
    ///                            collateral asset into debt asset to
    ///                            facilitate deleveraging.
    ///                         5. The amount of debt assets that will be
    ///                            repaid to lenders.
    ///                         6. Optional auxiliary data for execution of a
    ///                            deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory deleverageAction
    ) internal virtual override {
        SwapperLib.Swap[] memory swapActions = deleverageAction.swapAction;
        if (swapActions.length != 1) {
            revert BasePositionManager__InvalidParam();
        }

        address collateralAsset = deleverageAction.cToken.asset();
        address debtAsset = deleverageAction.borrowableCToken.asset();
        SwapperLib.Swap memory swapAction = swapActions[0];

        if (debtAsset == collateralAsset) {
            return;
        }

        if (swapAction.call.length == 0) {
            revert BasePositionManager__InvalidParam();
        }

        if (
            swapAction.target == address(0) ||
            swapAction.inputToken != collateralAsset ||
            swapAction.outputToken != debtAsset ||
            swapAction.inputAmount != deleverageAction.collateralAssets
        ) {
            revert BasePositionManager__InvalidParam();
        }

        // Swap collateral asset to debt asset.
        SwapperLib._swapSafe(centralRegistry, swapAction);
    }
}
