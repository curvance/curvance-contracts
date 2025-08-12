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

    /// @notice Deleverage callback: take the collateral asset already on hand and
    ///         swap it exactly once into the `debtAsset` using aggregator calldata.
    /// @dev This function does not redeem from a vault or perform native wrap/unwrap.
    ///      It enforces a single swap (`swapActions.length == 1`) and validates:
    ///        - non-empty `call`
    ///        - nonzero `target`
    ///        - `inputToken == action.cToken.asset()` (collateral asset)
    ///        - `outputToken == action.borrowableCToken.asset()` (debt asset)
    ///      The exact swap amount is encoded in the aggregator calldata; this function
    ///      does not validate it against `action.collateralAssets`.
    ///      The swap is executed via `SwapperLib._swapSafe`.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken whose underlying is the input token.
    ///               collateralAssets Collateral shares/amount context for the deleverage.
    ///               borrowableCToken The borrowable cToken whose asset will be repaid.
    ///               repayAssets Target repay amount in `debtAsset`.
    ///               swapActions Exactly one swap converting collateral asset -> debt asset.
    ///               auxData Optional auxiliary data for execution of a deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory action
    ) internal virtual override {
        address collateralAsset = action.cToken.asset();
        address debtAsset = action.borrowableCToken.asset();

        SwapperLib.Swap[] memory swapActions = action.swapActions;
        if (swapActions.length != 1) {
            revert BasePositionManager__InvalidParam();
        }

        if (
            swapActions[0].call.length == 0 ||
            swapActions[0].target == address(0) ||
            swapActions[0].inputToken != collateralAsset ||
            swapActions[0].outputToken != debtAsset
        ) {
            revert BasePositionManager__InvalidParam();
        }

        SwapperLib._swapSafe(centralRegistry, swapActions[0]);
    }
}
