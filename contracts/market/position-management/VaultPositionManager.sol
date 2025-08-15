// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

contract VaultPositionManager is SimplePositionManager {
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
    ) internal override {
        address debtAsset = action.borrowableCToken.asset();
        address vaultAddr = action.cToken.asset();
        IVault vault = IVault(vaultAddr);
        address underlying = address(vault.asset());
        
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

            // Swap `debtAsset` to vault `underlying`, update action assets.
            action.borrowAssets =
                SwapperLib._swapSafe(centralRegistry, swapAction);
        }

        // Validate we have tokens to deposit into the vault.
        if (action.borrowAssets == 0) {
            revert BasePositionManager__InvalidAmount();
        }

        SwapperLib._approveIfNeeded(underlying, vaultAddr, action.borrowAssets);
        vault.deposit(action.borrowAssets, address(this));
        SwapperLib._removeApprovalIfNeeded(underlying, vaultAddr);
    }
}