// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

contract VaultPositionManager is BasePositionManager {
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

    /// @notice Borrow callback: take borrowed `debtAsset`, optionally swap once to the
    ///         vault's underlying, then deposit all underlying into the ERC4626 vault to mint shares.
    /// @dev If `debtAsset == underlying`, no swap is performed. Otherwise this validates and executes
    ///      exactly one aggregator swap (`swapAction`) from `debtAsset` -> `underlying`, with
    ///      `inputAmount == action.borrowAssets`, then deposits the full resulting `underlying`.
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
        address underlying = address(vault.asset());
        address debtAsset = action.borrowableCToken.asset();

        // If the debt asset already matches the vault underlying, we skip swap.
        if (debtAsset != underlying) {
            SwapperLib.Swap memory swapAction = action.swapAction;

            if (
                swapAction.call.length == 0 ||
                swapAction.target == address(0) ||
                swapAction.inputToken != debtAsset ||
                swapAction.outputToken != underlying ||
                swapAction.inputAmount != action.borrowAssets
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap debt asset to vault underlying.
            SwapperLib._swapSafe(centralRegistry, swapAction);
        }

        uint256 depositAmount = IERC20(underlying).balanceOf(address(this));
        if (depositAmount == 0) {
            revert BasePositionManager__InvalidAmount();
        }

        SwapperLib._approveIfNeeded(underlying, vaultAddr, depositAmount);
        vault.deposit(depositAmount, address(this));
        SwapperLib._removeApprovalIfNeeded(underlying, vaultAddr);
    }

    /// @notice Redeem callback: redeem ERC4626 shares to the vault underlying, then optionally
    ///         swap once into the `debtAsset` for repayment.
    /// @dev Always redeems shares first. If `underlying == debtAsset`, no swap is performed.
    ///      Otherwise this validates and executes exactly one aggregator swap from
    ///      `underlying` -> `debtAsset` (`swapActions.length == 1`), then leaves the output
    ///      on this contract for repayment in the caller.
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
        address underlying = address(vault.asset());
        address debtAsset = action.borrowableCToken.asset();

        vault.redeem(action.collateralAssets, address(this), address(this));

        // If underlying is the same as the debtAsset, skip swap.
        if (underlying == debtAsset) {
            return;
        }

        SwapperLib.Swap memory swapAction = action.swapActions[0];

        if (
            swapAction.call.length == 0 ||
            swapAction.target == address(0) ||
            swapAction.inputToken != underlying ||
            swapAction.outputToken != debtAsset
        ) {
            revert BasePositionManager__InvalidParam();
        }

        SwapperLib._swapSafe(centralRegistry, swapAction);
    }
}