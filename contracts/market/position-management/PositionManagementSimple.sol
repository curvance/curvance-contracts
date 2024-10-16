// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementBase } from "contracts/market/position-management/PositionManagementBase.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract PositionManagementSimple is PositionManagementBase {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_
    ) PositionManagementBase(centralRegistry_, marketManager_) {}

    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.borrowToken.underlying();
        address collateralUnderlying = leverageData.positionToken.underlying();

        if (borrowUnderlying == collateralUnderlying) {
            return;
        }

        if (swapData.call.length == 0) {
            revert BasePositionManagement__InvalidSwapperParam();
        }

        if (
            swapData.target == address(0) ||
            swapData.inputToken != borrowUnderlying ||
            swapData.outputToken != collateralUnderlying ||
            swapData.inputAmount != leverageData.borrowAmount
        ) {
            revert BasePositionManagement__InvalidSwapperParam();
        }

        // Swap borrow underlying to collateral underlying.
        SwapperLib.swapSafe(centralRegistry, swapData);
    }

    function _swapCollateralToBorrowUnderlying(
        DeleverageStruct memory deleverageData
    ) internal virtual override {
        if (deleverageData.swapData.length != 1) {
            revert BasePositionManagement__InvalidSwapperParam();
        }

        SwapperLib.Swap memory swapData = deleverageData.swapData[0];
        address borrowUnderlying = deleverageData.borrowToken.underlying();
        address collateralUnderlying = deleverageData
            .positionToken
            .underlying();

        if (borrowUnderlying == collateralUnderlying) {
            return;
        }

        if (swapData.call.length == 0) {
            revert BasePositionManagement__InvalidSwapperParam();
        }

        if (
            swapData.target == address(0) ||
            swapData.inputToken != collateralUnderlying ||
            swapData.outputToken != borrowUnderlying ||
            swapData.inputAmount != deleverageData.collateralAmount
        ) {
            revert BasePositionManagement__InvalidSwapperParam();
        }

        // Swap collateral underlying to borrow underlying.
        SwapperLib.swapSafe(centralRegistry, swapData);
    }
}