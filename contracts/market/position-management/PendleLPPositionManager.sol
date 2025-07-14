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
    ///      `leverageData`.
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of `debtToken` that will be borrowed
    ///                        and swapped.
    ///                     2. The amount of underlying tokens from
    ///                        `debtToken` that will be borrowed.
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
        address lpToken = leverageData.collateralToken.asset();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();

        if (swapData.call.length == 0) {
            // check if borrow underlying is already in the form of sy input token
            if (!sy.isValidTokenIn(borrowUnderlying)) {
                revert BasePositionManager__InvalidParam();
            }
        } else {
            // check if swapData is valid
            if (
                swapData.target == address(0) ||
                swapData.inputToken != borrowUnderlying ||
                swapData.inputAmount != leverageData.borrowAmount ||
                !sy.isValidTokenIn(swapData.outputToken)
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // swap borrow underlying to sy input token
            SwapperLib._swapSafe(centralRegistry, swapData);
        }

        // decode pendle data
        (uint256 minLpAmount, PendleLib.PendleData memory pendleData) = abi
            .decode(leverageData.auxData, (uint256, PendleLib.PendleData));

        // enter pendle
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
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of the Curvance token that will be 
    ///                          routed into debt token underlying to repay
    ///                          outstanding debt.
    ///                       2. The amount of `collateralToken` that will be
    ///                          deleveraged.
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
        address lpToken = deleverageData.collateralToken.asset();
        address borrowUnderlying = deleverageData.debtToken.asset();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();

        address tokenOut;
        if (sy.isValidTokenOut(borrowUnderlying)) {
            tokenOut = borrowUnderlying;
        } else {
            if (deleverageData.swapData.length == 0) {
                revert BasePositionManager__InvalidParam();
            }
            SwapperLib.Swap memory swapData = deleverageData.swapData[0];
            tokenOut = swapData.inputToken;
        }

        // decode pendle data
        (uint256 minTokenOut, PendleLib.PendleData memory pendleData) = abi
            .decode(deleverageData.auxData, (uint256, PendleLib.PendleData));

        // exit pendle
        PendleLib._exitPendle(
            address(router),
            false,
            tokenOut,
            pendleData,
            lpToken,
            deleverageData.collateralAmount,
            minTokenOut
        );

        if (tokenOut != borrowUnderlying) {
            uint256 length = deleverageData.swapData.length;

            if (
                length == 0 ||
                deleverageData.swapData[0].inputToken != tokenOut ||
                deleverageData.swapData[length - 1].outputToken !=
                borrowUnderlying
            ) {
                revert BasePositionManager__InvalidParam();
            }

            // Swap sy output token for borrow underlying.
            for (uint256 i; i < length; ++i) {
                SwapperLib._swapSafe(
                    centralRegistry,
                    deleverageData.swapData[i]
                );
            }
        }
    }
}
