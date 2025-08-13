// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";

import { IVault } from "contracts/interfaces/IVault.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

abstract contract BaseVaultPositionManager is BasePositionManager {
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

	/// @notice Borrow callback: convert the borrowed `debtAsset` into the collateral
	///         asset accepted by the ERC4626 vault backing `action.cToken`, then
	///         deposit to mint shares.
	/// @dev This base implementation is abstract; concrete managers implement the route:
	///      - VaultPositionManager: swap `debtAsset` -> vault underlying (ERC20) once via
	///        an aggregator if needed, then deposit ERC20.
	///      - NativeVaultPositionManager: unwrap `wrappedNative` or swap once into native,
	///        then deposit native.
	///      Implementations must validate their swap (if any) and perform any needed approvals.
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
	) internal virtual override {}

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
    ) internal override {

        SwapperLib.Swap[] memory swapActions = action.swapActions;
        if (swapActions.length != 1) {
            revert BasePositionManager__InvalidParam();
        }

        address collateralAsset = action.cToken.asset();
        address debtAsset = action.borrowableCToken.asset();

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
