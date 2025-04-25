// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PositionManagementBase } from "contracts/market/position-management/PositionManagementBase.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IPYieldToken } from "contracts/interfaces/external/pendle/IPYieldToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

contract PositionManagementPendlePT is PositionManagementBase {
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
        PositionManagementBase(
            centralRegistry_,
            marketManager_,
            wrappedNative_
        )
    {
        router = router_;
    }

    /// INTERNAL FUNCTIONS ///

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
        LeverageStruct memory leverageData,
        address /* recipient */
    ) internal virtual override {
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.borrowToken.underlying();
        address ptToken = leverageData.positionToken.underlying();

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
            revert PositionManagementBase__InvalidSwapperParam();
        }

        if (swapData.call.length > 0) {
            // check if swapData is valid
            if (
                swapData.target == address(0) ||
                swapData.inputToken != borrowUnderlying ||
                swapData.inputAmount != leverageData.borrowAmount ||
                swapData.outputToken != pendleData.input.tokenIn
            ) {
                revert PositionManagementBase__InvalidSwapperParam();
            }

            SwapperLib.swapSafe(centralRegistry, swapData);
        }

        // Enter Pendle position.
        PendleLib.enterPendle(
            address(router),
            true,
            pendleData,
            lpToken,
            minPtAmount
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
        address ptToken = deleverageData.positionToken.underlying();
        address borrowUnderlying = deleverageData.borrowToken.underlying();

        // decode pendle data
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
            revert PositionManagementBase__InvalidSwapperParam();
        }

        // Exit Pendle position.
        PendleLib.exitPendle(
            address(router),
            true,
            ptToken,
            pendleData,
            lpToken,
            deleverageData.collateralAmount,
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
                revert PositionManagementBase__InvalidSwapperParam();
            }

            // Swap output token for borrow underlying.
            for (uint256 i; i < length; ++i) {
                SwapperLib.swapSafe(
                    centralRegistry,
                    deleverageData.swapData[i]
                );
            }
        }
    }
}
