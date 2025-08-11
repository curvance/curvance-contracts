// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";

import { IVault } from "contracts/interfaces/IVault.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

contract NativeVaultPositionManager is BasePositionManager {
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

    /// INTERNAL FUNCTIONS ///

    /// @notice Borrow callback: convert the debt asset to native (unwrap wrapped native
    ///         if already wrapped; otherwise swap once to native), then deposit native
    ///         into the ERC4626 vault to mint shares.
    /// @dev If `debtAsset == wrappedNative`, unwrap to native and deposit.
    ///      Otherwise validate and execute exactly one aggregator swap from
    ///      `debtAsset` -> native.
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
        address vaultAddr = action.cToken.asset();
        IVault vault = IVault(vaultAddr);
        address debtAsset = action.borrowableCToken.asset();

        uint256 nativeAmount;

        if (debtAsset == wrappedNative) {
            // Wrapped asset to native.
            IWETH(wrappedNative).withdraw(action.borrowAssets);
            nativeAmount = action.borrowAssets;
        } else {
            SwapperLib.Swap memory swapAction = action.swapAction;

            // Validate swap.
            if (
                swapAction.call.length == 0 ||
                swapAction.target == address(0) ||
                swapAction.inputToken != debtAsset ||
                swapAction.inputAmount != action.borrowAssets ||
                !CommonLib._isNative(swapAction.outputToken)
            ) {
                revert BasePositionManager__InvalidParam();
            }

            uint256 balBefore = address(this).balance;
            SwapperLib._swapSafe(centralRegistry, swapAction);
            nativeAmount = address(this).balance - balBefore;
        }

        if (nativeAmount == 0) {
            revert BasePositionManager__InvalidAmount();
        }

        vault.deposit{value: nativeAmount}(nativeAmount, address(this));
    }

    /// @notice Redeem callback: redeem ERC4626 shares to native, then optionally
    ///         convert to the `debtAsset` for repayment.
    /// @dev If `debtAsset == wrappedNative`, wrap native and return.
    ///      Otherwise validate and execute exactly one aggregator swap from
    ///      native -> `debtAsset` (`swapActions.length == 1`).
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
        address vaultAddr = action.cToken.asset();
        IVault vault = IVault(vaultAddr);
        address debtAsset = action.borrowableCToken.asset();

        // Redeem shares to native.
        uint256 nativeOut = vault.redeem(
            action.collateralAssets,
            address(this),
            address(this)
        );

        if (nativeOut == 0) {
            return;
        }

        if (debtAsset == wrappedNative) {
            // Wrap native to wrapped for repayment.
            IWETH(wrappedNative).deposit{value: nativeOut}();
            return;
        }

        SwapperLib.Swap[] memory swapActions = action.swapActions;
        if (swapActions.length != 1) {
            revert BasePositionManager__InvalidParam();
        }

        SwapperLib.Swap memory swapAction = swapActions[0];
        if (
            swapAction.call.length == 0 ||
            swapAction.target == address(0) ||
            !CommonLib._isNative(swapAction.inputToken) ||
            swapAction.outputToken != debtAsset
        ) {
            revert BasePositionManager__InvalidParam();
        }

        SwapperLib._swapSafe(centralRegistry, swapAction);
    }
}
