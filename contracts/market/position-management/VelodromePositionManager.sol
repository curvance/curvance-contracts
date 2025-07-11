// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BasePositionManager, SwapperLib, ICentralRegistry } from "contracts/market/position-management/BasePositionManager.sol";
import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract VelodromePositionManager is BasePositionManager {
    /// STORAGE ///
    
    /// @notice The address of the Velodrome pair factory.
    address public pairFactory;
    /// @notice The address of the Velodrome router.
    address public router;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_,
        address router_,
        address pairFactory_
    )
        BasePositionManager(
            centralRegistry_,
            marketManager_,
            wrappedNative_
        )
    {
        router = router_;
        pairFactory = pairFactory_;
    }

    /// @notice Callback function on borrowing tokens from an borrowableCToken
    ///         contract providing instant liquidity in the borrowableCToken
    ///         underlying which is then swapped into the underlying of a
    ///         cToken that a user is currently putting up as collateral
    ///         against the borrowableCToken debt position, creating a
    ///         leveraged spot position.
    /// @dev Slippage is checked inside enterVelodrome call to VelodromeLib
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
    /// @param recipient The user account who will receive the remaining dust
    ///                  post swap, if any.
    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData,
        address recipient
    ) internal virtual override {
        address pool = leverageData.collateralToken.asset();

        address token0 = IVeloPool(pool).token0();
        address token1 = IVeloPool(pool).token1();
        address borrowUnderlying = leverageData.debtToken.asset();

        // If the token being borrowed isn't token0 or token1 we will need to swap
        // into it.
        if (borrowUnderlying != token0 && borrowUnderlying != token1) {
            SwapperLib.Swap memory swapData = leverageData.swapData;
            // Make sure there is swap instructions.
            if (swapData.call.length == 0) {
                revert BasePositionManager__InvalidSwapperParam();
            }

            // Make sure the swap instructions are safe.
            if (
                swapData.target == address(0) ||
                swapData.inputToken != borrowUnderlying ||
                (swapData.outputToken != token0 &&
                    swapData.outputToken != token1) ||
                swapData.inputAmount != leverageData.borrowAmount
            ) {
                revert BasePositionManager__InvalidSwapperParam();
            }

            // Swap borrow underlying to token0.
            SwapperLib._swapSafe(centralRegistry, swapData);
        }

        uint256 totalAmountA = IERC20(token0).balanceOf(address(this));
        uint256 totalAmountB = IERC20(token1).balanceOf(address(this));
        // Validate swap was routed into token0/token1, or borrow token was token0/token1.
        if (totalAmountA == 0 && totalAmountB == 0) {
            revert BasePositionManager__InvalidSlippage();
        }
        
        uint256 minLpAmount = abi.decode(leverageData.auxData, (uint256));

        VelodromeLib._enterVelodrome(
            router,
            pairFactory,
            pool,
            totalAmountA,
            totalAmountB,
            minLpAmount
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
        address pool = deleverageData.collateralToken.asset();

        address borrowUnderlying = deleverageData.debtToken.asset();

        VelodromeLib._exitVelodrome(
            router,
            pool,
            deleverageData.collateralAmount
        );

        uint256 numSwaps = deleverageData.swapData.length;

        // Check to make sure there is calldata attached to execute the swap.
        if (numSwaps > 0) {
            address token0 = IVeloPool(pool).token0();
            address token1 = IVeloPool(pool).token1();

            if (
                (deleverageData.swapData[0].inputToken != token0 &&
                    deleverageData.swapData[0].inputToken != token1) ||
                deleverageData.swapData[numSwaps - 1].outputToken !=
                borrowUnderlying
            ) {
                revert BasePositionManager__InvalidSwapperParam();
            }

            for (uint256 i; i < numSwaps; ++i) {
                // Swap Swapper input token for borrow underlying.
                SwapperLib._swapSafe(
                    centralRegistry,
                    deleverageData.swapData[i]
                );
            }
        }
    }
}
