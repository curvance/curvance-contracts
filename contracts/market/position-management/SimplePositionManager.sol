// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";

contract SimplePositionManager is BasePositionManager {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_
    )
        BasePositionManager(
            centralRegistry_,
            marketManager_,
            wrappedNative_
        )
    {}

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
        address /* recipient */
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.debtToken.asset();
        address collateralUnderlying = leverageData.collateralToken.asset();

        if (borrowUnderlying == collateralUnderlying) {
            return;
        }

        if (swapData.call.length == 0) {
            revert BasePositionManager__InvalidSwapperParam();
        }

        if (
            swapData.target == address(0) ||
            swapData.inputToken != borrowUnderlying ||
            swapData.outputToken != collateralUnderlying ||
            swapData.inputAmount != leverageData.borrowAmount
        ) {
            revert BasePositionManager__InvalidSwapperParam();
        }

        // Swap borrow underlying to collateral underlying.
        SwapperLib._swapSafe(centralRegistry, swapData);
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
        if (deleverageData.swapData.length != 1) {
            revert BasePositionManager__InvalidSwapperParam();
        }

        SwapperLib.Swap memory swapData = deleverageData.swapData[0];
        address borrowUnderlying = deleverageData.debtToken.asset();
        address collateralUnderlying = deleverageData
            .collateralToken
            .asset();

        if (borrowUnderlying == collateralUnderlying) {
            return;
        }

        if (swapData.call.length == 0) {
            revert BasePositionManager__InvalidSwapperParam();
        }

        if (
            swapData.target == address(0) ||
            swapData.inputToken != collateralUnderlying ||
            swapData.outputToken != borrowUnderlying ||
            swapData.inputAmount != deleverageData.collateralAmount
        ) {
            revert BasePositionManager__InvalidSwapperParam();
        }

        // Swap collateral underlying to borrow underlying.
        SwapperLib._swapSafe(centralRegistry, swapData);
    }
}
