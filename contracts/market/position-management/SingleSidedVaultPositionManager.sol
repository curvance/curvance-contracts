// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

/// @title Curvance Single-Sided Vault Position Manager.
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
///      -> swap collateral assets for debt assets -> repay outstanding debt
///      with debt assets -> check that there is no liquidity shortfall from
///      the initial shares redeemed versus the newly decreased outstanding
///      debt.
///
///      The "Vault" contract is the position manager for working with
///      non-native erc4626 tokens such as sUSDe, that have a redemption
///      cooldown period. No type specific "_swapCollateralAssetToDebtAsset"
///      is written, execution is intended to be the same as the "simple"
///      position manager where collateral is simply swapped via dex
///      aggregator.
///
contract SingleSidedVaultPositionManager is SimplePositionManager {
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

    /// @notice Borrow callback: take borrowed `debtAsset`, optionally swap
    ///         once to the vault's underlying, then deposit all underlying
    ///         into the ERC4626 vault to mint shares.
    /// @dev If `debtAsset == underlying`, skip the swap step and deposit
    ///      directly. Otherwise, validate and execute exactly one aggregator
    ///      swap (`swapAction`) from `debtAsset` -> `underlying`, then
    ///      deposit the full resulting `underlying`.
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
        (address vault, address underlying) =
            _getVaultAndUnderlying(action.cToken.asset());

        // If the `debtAsset` already matches the vault underlying, we can
        // skip swapping.
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

        SwapperLib._approveIfNeeded(underlying, vault, action.borrowAssets);
        IVault(vault).deposit(action.borrowAssets, address(this));
        SwapperLib._removeApprovalIfNeeded(underlying, vault);
    }

    /// @notice Simple helper for getting vault address and corresponding
    ///         underlying token, potentially overridden in child
    ///         implementations for dual contract vault structures such as
    ///         Upshift.
    /// @param cTokenAddress The Curvance token address corresponding to a
    ///                      vault receipt token contract.
    /// @return vault The receipt token's vault address.
    /// @return underlying The address of the underlying asset of the receipt
    ///                    token of `vault`.
    function _getVaultAndUnderlying(
        address cTokenAddress
    ) internal virtual view returns (address vault, address underlying) {
        vault = cTokenAddress;
        underlying = address(IVault(vault).asset());
    }
}