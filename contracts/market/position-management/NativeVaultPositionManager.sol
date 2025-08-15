// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";

import { IVault } from "contracts/interfaces/IVault.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

contract NativeVaultPositionManager is SimplePositionManager {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative
    ) SimplePositionManager(cr, mm, wNative) {}

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
    ) internal override {
        address debtAsset = action.borrowableCToken.asset();

        if (debtAsset == wrappedNative) {
            // Wrapped asset to native.
            IWETH(wrappedNative).withdraw(action.borrowAssets);
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

            // Swap `debtAsset` to vault `underlying`, update action assets.
            action.borrowAssets =
                SwapperLib._swapSafe(centralRegistry, swapAction);
        }

        // Validate we have tokens to deposit into the vault.
        if (action.borrowAssets == 0) {
            revert BasePositionManager__InvalidAmount();
        }

        // Call the vault contract, the asset of the cToken.
        IVault(action.cToken.asset()).deposit{value: action.borrowAssets}
            (action.borrowAssets, address(this));
    }

}
