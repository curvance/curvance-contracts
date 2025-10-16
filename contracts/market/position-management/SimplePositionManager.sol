// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";

/// @title Curvance Simple Position Manager.
/// @notice Simple Asset-specific contract for executing leverage related
///         actions.
/// @dev Curvance Position Manager contracts enshrine actions that
///      usually would require multiple sequential actions to facilitate,
///      specifically leveraging a position up or deleveraging it for
///      withdrawal.
///
///      Curvance token contracts facilitate these operations through
///      enshrined integrations with Position Manager callback functions.
///
///      Typical workflow for:
///      Leverage -> borrow assets from a borrowableCToken -> swap debt assets
///      into collateral assets -> deposit collateral assets and collateralize
///      received shares -> check that there is no liquidity shortfall from
///      the initial assets borrowed versus the new collateralized shares.
///
///      Deleverage -> redeem collateralized shares from a cToken for assets
///      -> swap collateral assets for debt assets -> repay outstanding debt
///      with debt assets -> check that there is no liquidity shortfall from
///      the initial shares redeemed versus the newly decreased outstanding
///      debt.
///
///      The "Simple" contract is the position manager for working with
///      generic non-native erc20 tokens such as USDC or WETH.
///
contract SimplePositionManager is BasePositionManager {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative
    ) BasePositionManager(cr, mm, wNative) {}

    /// @notice Callback function on borrowing tokens from an borrowableCToken
    ///         contract providing instant liquidity in the borrowableCToken
    ///         underlying which is then swapped into the underlying of a
    ///         cToken that a user is currently putting up as collateral
    ///         against the borrowableCToken debt position, creating a
    ///         leveraged spot position.
    /// @param action Instructions for a leverage action containing:
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will be borrowed from and assets
    ///                                swapped into `cToken` asset.
    ///               borrowAssets The amount borrowed from
    ///                            `borrowableCToken`, in assets.
    ///               cToken Curvance token assets that borrowed funds will be
    ///                      swapped into.
    ///               swapAction Swap action instructions converting debt
    ///                          asset into collateral asset to facilitate
    ///                          leveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       leverage action.
    function _swapDebtAssetToCollateralAsset(
        LeverageAction memory action,
        address /* receiver */
    ) internal virtual override {
        SwapperLib.Swap memory swapAction = action.swapAction;
        address debtAsset = action.borrowableCToken.asset();
        address collateralAsset = action.cToken.asset();

        if (debtAsset == collateralAsset) {
            // No swap should be provided if assets match to avoid arbitrary calls.
            if (swapAction.call.length != 0 || swapAction.target != address(0)) {
                revert BasePositionManager__InvalidParam();
            }
            return;
        }

        if (
            swapAction.call.length == 0 ||
            swapAction.target == address(0) ||
            swapAction.inputToken != debtAsset ||
            swapAction.outputToken != collateralAsset ||
            swapAction.inputAmount != action.borrowAssets
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
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory action
    ) internal virtual override {
        SwapperLib.Swap[] memory swapActions = action.swapActions;
        
        // For simple actions there should only ever be one swap.
        if (swapActions.length != 1) {
            revert BasePositionManager__InvalidParam();
        }

        address collateralAsset = action.cToken.asset();
        address debtAsset = action.borrowableCToken.asset();
        SwapperLib.Swap memory swapAction = swapActions[0];

        if (debtAsset == collateralAsset) {
            // No swap should be provided if assets match to avoid arbitrary calls.
            if (swapAction.call.length != 0 || swapAction.target != address(0)) {
                revert BasePositionManager__InvalidParam();
            }
            return;
        }

        if (
            swapAction.call.length == 0 ||
            swapAction.target == address(0) ||
            swapAction.inputToken != collateralAsset ||
            swapAction.outputToken != debtAsset ||
            swapAction.inputAmount != action.collateralAssets
        ) {
            revert BasePositionManager__InvalidParam();
        }

        // Swap collateral asset to debt asset.
        SwapperLib._swapSafe(centralRegistry, swapAction);
    }
}
