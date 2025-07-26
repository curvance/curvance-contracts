// SPDX-License-Identifier: MIT
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
    /// @param leverageAction Instructions for a leverage action containing:
    ///                       borrowableCToken Address of the borrowableCToken
    ///                                        that will be borrowed from and
    ///                                        assets swapped into `cToken`
    ///                                        asset.
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
        address ptToken = leverageAction.cToken.asset();
        address debtAsset = leverageAction.borrowableCToken.asset();
        SwapperLib.Swap memory swapAction = leverageAction.swapAction;

        // Decode pendle data.
        (
            address lpToken,
            uint256 minPtAmount,
            PendleLib.PendleData memory pendleData
        ) = abi.decode(
                leverageAction.auxData,
                (address, uint256, PendleLib.PendleData)
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
                swapAction.inputAmount != leverageAction.borrowAssets ||
                swapAction.outputToken != pendleData.input.tokenIn
            ) {
                revert BasePositionManager__InvalidParam();
            }

            SwapperLib._swapSafe(centralRegistry, swapAction);
        }

        // Enter Pendle position.
        PendleLib._enterPendle(
            address(router),
            true,
            pendleData,
            lpToken,
            minPtAmount
        );
    }

    /// @notice Callback function on redemption of tokens from a cToken vault
    ///         providing instant liquidity in the cToken underlying which is
    ///         then swapped into the underlying of an borrowableCToken that a
    ///         user is currently borrowing from, partially or fully closing a
    ///         leveraged spot position.
    /// @param deleverageAction Instructions for a deleverage action
    ///                         containing:
    ///                         cToken Address of the cToken that will be
    ///                                redeemed from and assets swapped into
    ///                                `borrowableCToken` asset.
    ///                         collateralAssets The amount of `cToken` that
    ///                                          will be deleveraged,
    ///                                          in assets.
    ///                         borrowableCToken Address of the
    ///                                          borrowableCToken that will
    ///                                          have its debt paid.
    ///                         repayAssets The amount of `borrowableCToken`
    ///                                     asset that will be repaid to
    ///                                     lenders.
    ///                         swapAction Swap actions instructions
    ///                                    converting collateral asset into
    ///                                    debt asset to facilitate
    ///                                    deleveraging.
    ///                         auxData Optional auxiliary data for execution
    ///                                 of a deleverage action.
    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory deleverageAction
    ) internal virtual override {
        address ptToken = deleverageAction.cToken.asset();
        address debtAsset = deleverageAction.borrowableCToken.asset();
        SwapperLib.Swap[] memory swapActions = deleverageAction.swapActions;

        // Decode Pendle data.
        (address lpToken, PendleLib.PendleData memory pendleData) = abi.decode(
            deleverageAction.auxData,
            (address, PendleLib.PendleData)
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
            ptToken,
            pendleData,
            lpToken,
            deleverageAction.collateralAssets,
            0 // don't need for PT
        );

        uint256 numSwaps = swapActions.length;

        if (numSwaps > 0) {
            if (
                swapActions[0].inputToken != pendleData.output.tokenOut ||
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
