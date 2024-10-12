// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { CTokenPrimitive } from "contracts/market/collateral/CTokenPrimitive.sol";

import { BasePositionManagement } from "contracts/market/position-management/BasePositionManagement.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract SimplePositionManagement is BasePositionManagement {

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_
    ) BasePositionManagement(centralRegistry_, marketManager_) {}

    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.borrowToken.underlying();
        address collateralUnderlying = leverageData.collateralToken.underlying();

        if (borrowUnderlying == collateralUnderlying) {
            return;
        }

        if(swapData.call.length == 0) {
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

        // Swap borrow underlying to collateral underlying
        SwapperLib.swapSafe(
            centralRegistry,
            swapData
        );
    }

    function _swapCollateralToBorrowUnderyling(
        DeleverageStruct memory deleverageData
    ) internal virtual override {
        if (deleverageData.swapData.length != 1) {
            revert BasePositionManagement__InvalidSwapperParam();
        }

        SwapperLib.Swap memory swapData = deleverageData.swapData[0];
        address borrowUnderlying = deleverageData.borrowToken.underlying();
        address collateralUnderlying = deleverageData.collateralToken.underlying();

        if (borrowUnderlying == collateralUnderlying) {
            return;
        }

        if(swapData.call.length == 0) {
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

        // Swap collateral underlying to borrow underlying
        SwapperLib.swapSafe(
            centralRegistry,
            swapData
        );
    }
}