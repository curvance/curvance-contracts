// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;


import { PositionFoldingBase } from "contracts/market/position-folding/PositionFoldingBase.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract AerodromeStableCTokenPositionFolding is PositionFoldingBase {

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_
    ) PositionFoldingBase(centralRegistry_, marketManager_) {}

    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;

        if(swapData.call.length > 0) {
            
        }
    }

    function _swapCollateralToBorrowUnderyling(
        DeleverageStruct memory deleverageData
    ) internal virtual override {}
}