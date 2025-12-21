// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { SingleSidedVaultPositionManager } from "contracts/market/position-management/SingleSidedVaultPositionManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

/// @title Curvance Dual-Sided Vault Position Manager.
/// @notice Vault-specific contract for executing leverage related actions.
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
///      -> redeem vault shares for debt assets -> repay outstanding debt
///      with debt assets -> check that there is no liquidity shortfall from
///      the initial shares redeemed versus the newly decreased outstanding
///      debt.
///
///      The "Vault" contract is the position manager for working with
///      non-native erc4626 tokens such as sAUSD, which have no redemption
///      cooldown period.
///
contract DualSidedVaultPositionManager is SingleSidedVaultPositionManager {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative
    ) SingleSidedVaultPositionManager(cr, mm, wNative) {}

    /// INTERNAL FUNCTIONS ///

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
    ///               repayAssets The minimum amount, in assets, to be
    ///                           creditable to caller through repayment
    ///                           and/or direct transfer.
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory action
    ) internal virtual override {
        address debtAsset = action.borrowableCToken.asset();
        address vaultAddr = action.cToken.asset();
        (IVault vault, address underlying) =
            _getVaultAndUnderlying(vaultAddr);

        // Validate we have tokens to redeem from the vault.
        if (action.collateralAssets == 0) {
            revert BasePositionManager__InvalidAmount();
        }

        SwapperLib.
            _approveIfNeeded(underlying, vaultAddr, action.collateralAssets);
        uint256 assets =
            vault.redeem(action.collateralAssets, address(this), address(this));
        SwapperLib._removeApprovalIfNeeded(underlying, vaultAddr);

        // If the `debtAsset` already matches the vault underlying, we can
        // skip swapping.
        if (debtAsset != underlying) {
            // For vault position manager actions there should only ever
            // be one swap at most.
            if (action.swapActions.length != 1) {
                revert BasePositionManager__InvalidParam();
            }

            // Load the one swap action.
            SwapperLib.Swap memory swapAction = action.swapActions[0];

            if (
                swapAction.call.length == 0 ||
                swapAction.target == address(0) ||
                swapAction.inputToken != underlying ||
                swapAction.outputToken != debtAsset ||
                swapAction.inputAmount != action.collateralAssets
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // If we got more assets than anticipated, swap the full amount
            // to receive more `debtAssets`.
            swapAction.inputAmount = assets;

            // Swap `underlying` to vault `debtAsset`.
            SwapperLib._swapSafe(centralRegistry, swapAction);
        }
    }
}