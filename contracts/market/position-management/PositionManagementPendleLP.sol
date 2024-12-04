// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementBase } from "contracts/market/position-management/PositionManagementBase.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

contract PositionManagementPendleLP is PositionManagementBase {
    IPendleRouter public router;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        IPendleRouter router_
    ) PositionManagementBase(centralRegistry_, marketManager_) {
        router = router_;
    }

    /// @notice Callback function on borrowing tokens from an eToken contract
    ///         providing instant liquidity in the eToken underlying which is
    ///         then swapped into the underlying of a pToken that a user is
    ///         currently putting up as collateral against the eToken debt
    ///         position, creating a leveraged spot position.
    /// @param leverageData Struct containing information on the desired
    ///                     leverage action to execute. Containing values:
    ///                     1. Address of eToken that will be borrowed from.
    ///                     2. The amount of underlying tokens from eToken
    ///                        that will be borrowed.
    ///                     3. Address of pToken that borrowed funds
    ///                        will be swapped into.
    ///                     4. Struct containing instructions
    ///                        on how to handle the necessary eToken swap
    ///                        to facilitate leveraging.
    ///                     5. Optional auxiliary data for execution of a
    ///                        leverage action.
    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.borrowToken.underlying();
        address lpToken = leverageData.positionToken.underlying();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();

        if (swapData.call.length == 0) {
            // check if borrow underlying is already in the form of sy input token
            if (!sy.isValidTokenIn(borrowUnderlying)) {
                revert PositionManagementBase__InvalidSwapperParam();
            }
        } else {
            // check if swapData is valid
            if (
                swapData.target == address(0) ||
                swapData.inputToken != borrowUnderlying ||
                !sy.isValidTokenIn(swapData.outputToken)
            ) {
                revert PositionManagementBase__InvalidSwapperParam();
            }

            // swap borrow underlying to sy input token
            SwapperLib.swapSafe(centralRegistry, swapData);
        }

        // decode pendle data
        (uint256 minLpAmount, PendleLib.PendleData memory pendleData) = abi
            .decode(leverageData.auxData, (uint256, PendleLib.PendleData));

        // enter pendle
        PendleLib.enterPendle(
            address(router),
            false,
            pendleData,
            lpToken,
            minLpAmount
        );
    }

    /// @notice Callback function on redemption of tokens from a pToken vault
    ///         providing instant liquidity in the pToken underlying which is
    ///         then swapped into the underlying of an eToken that a user is
    ///         currently borrowing from, partially or fully closing a
    ///         leveraged spot position.
    /// @param deleverageData Struct containing information on the desired
    ///                       deleverage action to execute. Containing values:
    ///                       1. Address of pToken that will be routed into
    ///                          eToken underlying to repay outstanding debt.
    ///                       2. The amount of pTokens that will be
    ///                          deleveraged.
    ///                       3. Address of eToken that will have its underlying
    ///                          token debt repaid.
    ///                       4. Optional struct containing instructions on how
    ///                          to handle swapping into eToken underlying to
    ///                          facilitate deleveraging.
    ///                       5. The amount of underlying tokens that will be
    ///                          repaid to the eToken lenders.
    ///                       6. Optional auxiliary data for execution of a
    ///                          deleverage action.
    function _swapCollateralToBorrowUnderlying(
        DeleverageStruct memory deleverageData
    ) internal virtual override {
        address lpToken = deleverageData.positionToken.underlying();
        address borrowUnderlying = deleverageData.borrowToken.underlying();
        (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();

        address tokenOut;
        if (sy.isValidTokenOut(borrowUnderlying)) {
            tokenOut = borrowUnderlying;
        } else {
            if (deleverageData.swapData.length == 0) {
                revert PositionManagementBase__InvalidSwapperParam();
            }
            SwapperLib.Swap memory swapData = deleverageData.swapData[0];
            tokenOut = swapData.inputToken;
        }

        // decode pendle data
        PendleLib.PendleData memory pendleData = abi.decode(
            deleverageData.auxData,
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
