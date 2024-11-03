// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { CTokenPrimitive, IERC20 } from "contracts/market/collateral/CTokenPrimitive.sol";

import { BasePositionManagement } from "contracts/market/position-management/BasePositionManagement.sol";
import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract VelodromeVolatilePositionManagement is BasePositionManagement {

    address public pairFactory;

    address public router;

    /// ERRORS ///
    
    error VelodromeVolatilePositionManagement__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address router_,
        address pairFactory_
    ) BasePositionManagement(centralRegistry_, marketManager_) {
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
    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual override {
        // Cache asset to minimize storage reads.
        address pool = leverageData.collateralToken.underlying();
        address _asset = pool;
        address token0 = IVeloPool(_asset).token0();
        address token1 = IVeloPool(_asset).token1();
        
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.borrowToken.underlying();

        if (borrowUnderlying != token0) {
            if(swapData.call.length == 0) {
                revert BasePositionManagement__InvalidSwapperParam();
            }

            if (
                swapData.target == address(0) ||
                swapData.inputToken != borrowUnderlying ||
                swapData.outputToken != token0 ||
                swapData.inputAmount != leverageData.borrowAmount
            ) {
                revert BasePositionManagement__InvalidSwapperParam();
            }

            // Swap borrow underlying to token0
            SwapperLib.swapSafe(
                centralRegistry,
                swapData
            );
        }

        uint256 totalAmountA = IERC20(token0).balanceOf(address(this));
        // Make sure swap was routed into token0, or that token0 is AERO.
        if (totalAmountA == 0) {
            revert VelodromeVolatilePositionManagement__SlippageError();
        }

        {   
            uint256 decimalsA = 10 ** IERC20(token0).decimals();
            uint256 decimalsB = 10 ** IERC20(token1).decimals();
            // Pull reserve data so we can swap half of token0 into token1
            // optimally.
            (uint256 r0, uint256 r1, ) = IVeloPair(_asset).getReserves();
            (uint256 reserveA, uint256 reserveB) = token0 ==
                IVeloPair(_asset).token0()
                ? (r0, r1)
                : (r1, r0);
            // Feed library pair factory, lpToken, and stable = false,
            // plus calculated data.
            uint256 swapAmount = VelodromeLib._optimalDeposit(
                pairFactory,
                _asset,
                totalAmountA,
                reserveA,
                reserveB,
                decimalsA,
                decimalsB,
                false
            );
            // Feed calculated data, and stable = false.
            VelodromeLib._swapExactTokensForTokens(
                router,
                _asset,
                token0,
                token1,
                swapAmount,
                false
            );
            totalAmountA -= swapAmount;
        }

        // Add liquidity to Aerodrome lp with stable params.
        VelodromeLib._addLiquidity(
            router,
            token0,
            token1,
            false,
            totalAmountA,
            IERC20(token1).balanceOf(address(this)), // totalAmountB
            VelodromeLib.VELODROME_ADD_LIQUIDITY_SLIPPAGE
        );
    }

    /// @notice Callback function on redemption of tokens from a pToken vault
    ///         providing instant liquidity in the pToken underlying which is
    ///         then swapped into the underlying of an eToken that a user is
    ///         currently borrowing from, partially or fully closing a
    ///         leveraged spot position.
    /// @param swapData Optional Swapperlib swapping struct containing
    ///                 instructions on how to handle zapping into dToken
    ///                 underlying to facilitate deleveraging.
    /// @param repayAmount The amount of underlying tokens from dToken that
    ///                    will be repaid.
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
        address pool = deleverageData.collateralToken.underlying();

        VelodromeLib.exitVelodrome(
            router,
            pool,
            deleverageData.collateralAmount
        );

        // Check to make sure there is calldata attached to execute the swap.
        if (deleverageData.swapData.length > 0) {
            for (uint256 i; i < deleverageData.swapData.length; ++i) {
                // Swap Swapper input token for borrow underlying.
                SwapperLib.swapSafe(
                    centralRegistry,
                    deleverageData.swapData[i]
                );
            }
        }
    }
}