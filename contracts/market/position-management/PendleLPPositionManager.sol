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

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_,
        IPendleRouter router_
    )
        BasePositionManager(
            centralRegistry_,
            marketManager_,
            wrappedNative_
        )
    {
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
    ///      `leverageAction`.
    /// @param leverageAction Instructions for a leverage action containing:
    ///                       borrowableCToken Address of `borrowableCToken`
    ///                                        that will be borrowed from and
    ///                                        assets swapped.
    ///                       borrowAssets The amount borrowed from
    ///                                    `borrowableCToken`, in assets.
    ///                       cToken Curvance token assets that borrowed funds
    ///                              will be swapped into.
    ///                       swapAction Swap action instructions converting
    ///                                  debt asset into collateral asset to
    ///                                  facilitate leveraging.
    ///                       auxData Optional auxiliary data for execution of a
    ///                               a leverage action.
    function _swapDebtAssetToCollateralAsset(
        LeverageAction memory leverageAction,
        address /* receiver */
    ) internal virtual override {
        address debtAsset = leverageAction.borrowableCToken.asset();
        address lpToken = leverageAction.cToken.asset();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();
        SwapperLib.Swap memory swapAction = leverageAction.swapAction;

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
                swapAction.inputAmount != leverageAction.borrowAssets ||
                !sy.isValidTokenIn(swapAction.outputToken)
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap debt asset to sy input token.
            SwapperLib._swapSafe(centralRegistry, swapAction);
        }

        // Decode pendle data.
        (uint256 minLpAmount, PendleLib.PendleData memory pendleData) = abi
            .decode(leverageAction.auxData, (uint256, PendleLib.PendleData));

        // Enter pendle position.
        PendleLib._enterPendle(
            address(router),
            false,
            pendleData,
            lpToken,
            minLpAmount
        );
    }

    /// @notice Callback function on redemption of tokens from a cToken vault
    ///         providing instant liquidity in the cToken underlying which is
    ///         then swapped into the underlying of an borrowableCToken that a
    ///         user is currently borrowing from, partially or fully closing a
    ///         leveraged spot position.
    /// @param deleverageAction Struct containing information on a deleverage
    ///                         action to execute. Containing values:
    ///                         1. Address of the cToken whose asset will be
    ///                            routed into debt asset to repay outstanding
    ///                            debt.
    ///                         2. The amount of `cToken` that will
    ///                            be deleveraged.
    ///                         3. Address of borrowableCToken that will have
    ///                            its outstanding debt repaid.
    ///                         4. Swap action instructions converting
    ///                            collateral asset into debt asset to
    ///                            facilitate deleveraging.
    ///                         5. The amount of debt assets that will be
    ///                            repaid to lenders.
    ///                         6. Optional auxiliary data for execution of a
    ///                            deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory deleverageAction
    ) internal virtual override {
        address lpToken = deleverageAction.cToken.asset();
        address debtAsset = deleverageAction.borrowableCToken.asset();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();
        SwapperLib.Swap[] memory swapActions = deleverageAction.swapAction;

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
        (uint256 minTokenOut, PendleLib.PendleData memory pendleData) = abi
            .decode(deleverageAction.auxData, (uint256, PendleLib.PendleData));

        // Exit Pendle position.
        PendleLib._exitPendle(
            address(router),
            false,
            tokenOut,
            pendleData,
            lpToken,
            deleverageAction.collateralAssets,
            minTokenOut
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
