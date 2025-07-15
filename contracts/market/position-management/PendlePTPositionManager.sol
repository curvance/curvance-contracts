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
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of `debtToken` that will be borrowed
    ///                        and swapped.
    ///                     2. The amount of underlying tokens from
    ///                        `debtToken` that will be borrowed, in assets.
    ///                     3. Curvance token that borrowed funds will be
    ///                        swapped into.
    ///                     4. Struct containing instructions on how
    ///                        to handle the necessary swap to 
    ///                        facilitate leveraging.
    ///                     5. Optional auxiliary data for execution of a
    ///                        leverage action.
    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData,
        address /* receiver */
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.debtToken.asset();
        address ptToken = leverageData.collateralToken.asset();

        // decode pendle data
        (
            address lpToken,
            uint256 minPtAmount,
            PendleLib.PendleData memory pendleData
        ) = abi.decode(
                leverageData.auxData,
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

        if (swapData.call.length > 0) {
            // check if swapData is valid
            if (
                swapData.target == address(0) ||
                swapData.inputToken != borrowUnderlying ||
                swapData.inputAmount != leverageData.borrowAssets ||
                swapData.outputToken != pendleData.input.tokenIn
            ) {
                revert BasePositionManager__InvalidParam();
            }

            SwapperLib._swapSafe(centralRegistry, swapData);
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
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of the Curvance token that will be 
    ///                          routed into debt token underlying to repay
    ///                          outstanding debt.
    ///                       2. The amount of `collateralToken` that will be
    ///                          deleveraged, in assets.
    ///                       3. Address of Curvance token that will have its
    ///                          outstanding debt repaid.
    ///                       4. Optional struct containing instructions on
    ///                          how to handle swapping into debt token to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    function _swapCollateralToBorrowUnderlying(
        DeleverageStruct memory deleverageData
    ) internal virtual override {
        address ptToken = deleverageData.collateralToken.asset();
        address borrowUnderlying = deleverageData.debtToken.asset();

        // Decode Pendle data.
        (address lpToken, PendleLib.PendleData memory pendleData) = abi.decode(
            deleverageData.auxData,
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
            deleverageData.collateralAssets,
            0 // don't need for PT
        );

        uint256 length = deleverageData.swapData.length;

        if (length > 0) {
            if (
                deleverageData.swapData[0].inputToken !=
                pendleData.output.tokenOut ||
                deleverageData.swapData[length - 1].outputToken !=
                borrowUnderlying
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap output token for borrow underlying.
            for (uint256 i; i < length; ++i) {
                SwapperLib._swapSafe(
                    centralRegistry,
                    deleverageData.swapData[i]
                );
            }
        }
    }
}
