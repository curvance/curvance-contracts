// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementBase } from "contracts/market/position-management/PositionManagementBase.sol";

import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";

contract PositionManagementVelodromeVolatile is PositionManagementBase {
    address public pairFactory;

    address public router;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_,
        address router_,
        address pairFactory_
    )
        PositionManagementBase(
            centralRegistry_,
            marketManager_,
            wrappedNative_
        )
    {
        router = router_;
        pairFactory = pairFactory_;
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
    /// @param recipient The user account who will receive the remaining dust
    ///                  post swap, if any.
    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData,
        address recipient
    ) internal virtual override {
        address pool = leverageData.positionToken.underlying();
        address token0 = IVeloPair(pool).token0();
        address token1 = IVeloPair(pool).token1();

        address borrowUnderlying = leverageData.borrowToken.underlying();

        // If the token being borrowed isn't token0 we will need to swap
        // into it.
        if (borrowUnderlying != token0) {
            SwapperLib.Swap memory swapData = leverageData.swapData;
            // Make sure there is swap instructions.
            if (swapData.call.length == 0) {
                revert PositionManagementBase__InvalidSwapperParam();
            }

            // Make sure the swap instructions are safe.
            if (
                swapData.target == address(0) ||
                swapData.inputToken != borrowUnderlying ||
                swapData.outputToken != token0 ||
                swapData.inputAmount != leverageData.borrowAmount
            ) {
                revert PositionManagementBase__InvalidSwapperParam();
            }

            // Swap borrow underlying to token0.
            SwapperLib.swapSafe(centralRegistry, swapData);
        }

        // Validate swap was routed into token0, or borrow token was token0.
        uint256 totalAmountA = IERC20(token0).balanceOf(address(this));
        if (totalAmountA == 0) {
            revert PositionManagementBase__InvalidSlippage();
        }

        uint256 decimalsA = 10 ** IERC20(token0).decimals();
        uint256 decimalsB = 10 ** IERC20(token1).decimals();
        // Pull reserve data so we can swap half of token0 into token1
        // optimally.
        (uint256 r0, uint256 r1, ) = IVeloPair(pool).getReserves();
        (uint256 reserveA, uint256 reserveB) = token0 ==
            IVeloPair(pool).token0()
            ? (r0, r1)
            : (r1, r0);

        // Feed library pair factory, lpToken, and stable = false,
        // plus calculated data.
        uint256 swapAmount = VelodromeLib._optimalDeposit(
            pairFactory,
            pool,
            totalAmountA,
            reserveA,
            reserveB,
            decimalsA,
            decimalsB,
            false
        );
        // Feed calculated data, and stable = false.
        uint256 totalAmountB = VelodromeLib._swapExactTokensForTokens(
            router,
            pool,
            token0,
            token1,
            swapAmount,
            false
        );

        // Decrement amount of token0 swapped into token1.
        totalAmountA -= swapAmount;

        // Add liquidity to Velodrome lp with volatile params.
        VelodromeLib._addLiquidity(
            router,
            token0,
            token1,
            false,
            totalAmountA,
            totalAmountB,
            VelodromeLib.VELODROME_ADD_LIQUIDITY_SLIPPAGE
        );

        // We can reuse totalAmount variables to avoid stack too deep error
        // and minimize storage warming from 0 -> number.
        totalAmountA = IERC20(token0).balanceOf(address(this));
        totalAmountB = IERC20(token1).balanceOf(address(this));

        if (totalAmountA > 0) {
            _transferToRecipient(token0, recipient, totalAmountA);
        }

        if (totalAmountB > 0) {
            _transferToRecipient(token1, recipient, totalAmountB);
        }
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
        address pool = deleverageData.positionToken.underlying();
        address borrowUnderlying = deleverageData.borrowToken.underlying();

        VelodromeLib.exitVelodrome(
            router,
            pool,
            deleverageData.collateralAmount
        );

        uint256 length = deleverageData.swapData.length;

        // Check to make sure there is calldata attached to execute the swap.
        if (length > 0) {
            address token0 = IVeloPair(pool).token0();
            address token1 = IVeloPair(pool).token1();

            if (
                (deleverageData.swapData[0].inputToken != token0 &&
                    deleverageData.swapData[0].inputToken != token1) ||
                deleverageData.swapData[length - 1].outputToken !=
                borrowUnderlying
            ) {
                revert PositionManagementBase__InvalidSwapperParam();
            }

            for (uint256 i; i < length; ++i) {
                // Swap Swapper input token for borrow underlying.
                SwapperLib.swapSafe(
                    centralRegistry,
                    deleverageData.swapData[i]
                );
            }
        }
    }
}
