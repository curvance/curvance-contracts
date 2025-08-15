// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";

import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IPYieldToken } from "contracts/interfaces/external/pendle/IPYieldToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

contract PendlePTPositionManager is BasePositionManager {
    /// STORAGE /// 

    /// @notice The address of the Pendle router.
    IPendleRouter public router;

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wNative The address of wrapped native token.
    /// @param router_ Address of the Pendle router.
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative,
        IPendleRouter router_
    ) BasePositionManager(cr, mm, wNative) {
        router = router_;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Callback function on borrowing tokens from an borrowableCToken
    ///         contract providing instant liquidity in the borrowableCToken
    ///         underlying which is then swapped into the underlying of a
    ///         cToken that a user is currently putting up as collateral
    ///         against the borrowableCToken debt position, creating a
    ///         leveraged spot position.
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
        address ptToken = action.cToken.asset();
        address debtAsset = action.borrowableCToken.asset();
        SwapperLib.Swap memory swapAction = action.swapAction;

        // Decode pendle data.
        (
            address lpToken,
            uint256 minPtAmount,
            PendleLib.PendleAction memory pendleAction
        ) = abi.decode(
                action.auxData,
                (address, uint256, PendleLib.PendleAction)
            );

        (
            IStandardizedYield _SY,
            IPPrincipalToken _PT,
            IPYieldToken _YT
        ) = IPMarket(lpToken).readTokens();
        // check if valid ptToken of market
        if (
            address(_PT) != ptToken ||
            IPPrincipalToken(ptToken).SY() != address(_SY) ||
            IPPrincipalToken(ptToken).YT() != address(_YT)
        ) {
            revert BasePositionManager__InvalidParam();
        }

        if (swapAction.call.length > 0) {
            // check if swapAction is valid
            if (
                swapAction.target == address(0) ||
                swapAction.inputToken != debtAsset ||
                swapAction.inputAmount != action.borrowAssets ||
                swapAction.outputToken != pendleAction.input.tokenIn
            ) {
                revert BasePositionManager__InvalidParam();
            }

            SwapperLib._swapSafe(centralRegistry, swapAction);
        }

        // Enter Pendle position.
        PendleLib._enterPendle(
            address(router),
            true,
            lpToken,
            minPtAmount,
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
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory action
    ) internal virtual override {
        address ptToken = action.cToken.asset();
        address debtAsset = action.borrowableCToken.asset();
        SwapperLib.Swap[] memory swapActions = action.swapActions;

        // Decode Pendle data.
        (
            address lpToken,
            PendleLib.PendleAction memory pendleAction
        ) = abi.decode(
            action.auxData,
            (address, PendleLib.PendleAction)
        );

        (
            IStandardizedYield _SY,
            IPPrincipalToken _PT,
            IPYieldToken _YT
        ) = IPMarket(lpToken).readTokens();
        // check if valid ptToken of market
        if (
            address(_PT) != ptToken ||
            IPPrincipalToken(ptToken).SY() != address(_SY) ||
            IPPrincipalToken(ptToken).YT() != address(_YT)
        ) {
            revert BasePositionManager__InvalidParam();
        }

        // Exit Pendle position.
        PendleLib._exitPendle(
            address(router),
            true,
            lpToken,
            0, // don't need for PT
            pendleAction,
            ptToken,
            action.collateralAssets
        );

        uint256 numSwaps = swapActions.length;

        if (numSwaps > 0) {
            if (
                swapActions[0].inputToken != pendleAction.output.tokenOut ||
                swapActions[numSwaps - 1].outputToken != debtAsset
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap output token for debt asset.
            for (uint256 i; i < numSwaps; ++i) {
                SwapperLib._swapSafe(centralRegistry, swapActions[i]);
            }
        }
    }
}
