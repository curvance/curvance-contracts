// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BasePositionManagement } from "contracts/market/position-management/BasePositionManagement.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IPYieldToken } from "contracts/interfaces/external/pendle/IPYieldToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

contract PendleLPPositionManagement is BasePositionManagement {
    IPendleRouter public router;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        IPendleRouter router_
    ) BasePositionManagement(centralRegistry_, marketManager_) {
        router = router_;
    }

    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.borrowToken.underlying();
        address lpToken = leverageData.collateralToken.underlying();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();

        if (swapData.call.length == 0) {
            // check if borrow underlying is already in the form of sy input token
            if (!sy.isValidTokenIn(borrowUnderlying)) {
                revert BasePositionManagement__InvalidSwapperParam();
            }
        } else {
            // check if swapData is valid
            if (
                swapData.target == address(0) ||
                swapData.inputToken != borrowUnderlying ||
                swapData.inputAmount != leverageData.borrowAmount ||
                !sy.isValidTokenIn(swapData.outputToken)
            ) {
                revert BasePositionManagement__InvalidSwapperParam();
            }

            // swap borrow underlying to sy input token
            SwapperLib.swapSafe(centralRegistry, swapData);
        }

        // decode pendle data
        (uint256 minLpAmount, PendleLib.PendleData memory pendleData) = abi
            .decode(leverageData.data, (uint256, PendleLib.PendleData));

        // enter pendle
        PendleLib.enterPendle(
            address(router),
            false,
            pendleData,
            lpToken,
            minLpAmount
        );
    }

    function _swapCollateralToBorrowUnderyling(
        DeleverageStruct memory deleverageData
    ) internal virtual override {
        address lpToken = deleverageData.collateralToken.underlying();
        address borrowUnderlying = deleverageData.borrowToken.underlying();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();

        address tokenOut;
        if (sy.isValidTokenOut(borrowUnderlying)) {
            tokenOut = borrowUnderlying;
        } else {
            if (deleverageData.swapData.length == 0) {
                revert BasePositionManagement__InvalidSwapperParam();
            }
            SwapperLib.Swap memory swapData = deleverageData.swapData[0];
            tokenOut = swapData.inputToken;
        }

        // decode pendle data
        PendleLib.PendleData memory pendleData = abi.decode(
            deleverageData.data,
            (PendleLib.PendleData)
        );

        // exit pendle
        PendleLib.exitPendle(
            address(router),
            false,
            tokenOut,
            pendleData,
            lpToken,
            deleverageData.collateralAmount
        );

        if (tokenOut != borrowUnderlying) {
            // Swap sy output token for borrow underlying.
            for (uint256 i; i < deleverageData.swapData.length; ++i) {
                SwapperLib.swapSafe(
                    centralRegistry,
                    deleverageData.swapData[i]
                );
            }
        }
    }
}
