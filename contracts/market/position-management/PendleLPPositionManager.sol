// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";

import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

contract PendleLPPositionManager is BasePositionManager {
    /// STORAGE ///
    
    /// @notice The address of the Pendle router.
    IPendleRouter public router;

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wrappedNative_ The address of wrapped native token.
    /// @param router_ Address of the Pendle router.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wrappedNative_,
        IPendleRouter router_
    ) BasePositionManager(cr, mm, wrappedNative_) {
        router = router_;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Callback function on borrowing tokens from an borrowableCToken
    ///         contract providing instant liquidity in the borrowableCToken
    ///         underlying which is then swapped into the underlying of a
    ///         cToken that a user is currently putting up as collateral
    ///         against the borrowableCToken debt position, creating a
    ///         leveraged spot position.
    /// @dev Slippage is checked inside enterPendle call to PendleLib
    ///      with the slippage value being encoded in the `aux` field of
    ///      `action`.
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
        address debtAsset = action.borrowableCToken.asset();
        address lpToken = action.cToken.asset();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();
        SwapperLib.Swap memory swapAction = action.swapAction;

        if (swapAction.call.length == 0) {
            // Check if `debtAsset` is already in the form of sy input token.
            if (!sy.isValidTokenIn(debtAsset)) {
                revert BasePositionManager__InvalidParam();
            }
        } else {
            // Check if swapAction is valid.
            if (
                swapAction.target == address(0) ||
                swapAction.inputToken != debtAsset ||
                swapAction.inputAmount != action.borrowAssets ||
                !sy.isValidTokenIn(swapAction.outputToken)
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap debt asset to sy input token.
            SwapperLib._swapSafe(centralRegistry, swapAction);
        }

        // Decode pendle data.
        (uint256 minLpAmount, PendleLib.PendleAction memory pendleAction) = abi
            .decode(action.auxData, (uint256, PendleLib.PendleAction));

        // Enter pendle position.
        PendleLib._enterPendle(
            address(router),
            false,
            lpToken,
            minLpAmount,
            pendleAction
        );
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
    ///               swapAction Swap actions instructions converting
    ///                          collateral asset into debt asset to
    ///                          facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory action
    ) internal virtual override {
        address lpToken = action.cToken.asset();
        address debtAsset = action.borrowableCToken.asset();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();
        SwapperLib.Swap[] memory swapActions = action.swapActions;

        address tokenOut;
        if (sy.isValidTokenOut(debtAsset)) {
            tokenOut = debtAsset;
        } else {
            if (swapActions.length == 0) {
                revert BasePositionManager__InvalidParam();
            }

            SwapperLib.Swap memory swapAction = swapActions[0];
            tokenOut = swapAction.inputToken;
        }

        // Decode Pendle data.
        (uint256 minTokenOut, PendleLib.PendleAction memory pendleAction) = abi
            .decode(action.auxData, (uint256, PendleLib.PendleAction));

        // Exit Pendle position.
        PendleLib._exitPendle(
            address(router),
            false,
            lpToken,
            minTokenOut,
            pendleAction,
            tokenOut,
            action.collateralAssets
        );

        if (tokenOut != debtAsset) {
            uint256 numSwaps = swapActions.length;

            if (
                numSwaps == 0 || swapActions[0].inputToken != tokenOut ||
                swapActions[numSwaps - 1].outputToken != debtAsset
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap sy output token for debt asset.
            for (uint256 i; i < numSwaps; ++i) {
                SwapperLib._swapSafe(centralRegistry, swapActions[i]);
            }
        }
    }
}
