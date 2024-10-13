// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementBase } from "contracts/market/position-management/PositionManagementBase.sol";

import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

contract PositionManagementVelodromeVolatile is PositionManagementBase {

    address public pairFactory;

    address public router;

    /// ERRORS ///
    
    error PositionManagementVelodromeVolatile__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address router_,
        address pairFactory_
    ) PositionManagementBase(centralRegistry_, marketManager_) {
        router = router_;
        pairFactory = pairFactory_;
    }

    function _swapBorrowUnderlyingToCollateral(
        LeverageStruct memory leverageData
    ) internal virtual override {
        // Cache asset to minimize storage reads.
        address pool = leverageData.positionToken.underlying();
        address _asset = pool;
        address token0 = IVeloPool(_asset).token0();
        address token1 = IVeloPool(_asset).token1();
        
        SwapperLib.Swap memory swapData = leverageData.swapData;
        address borrowUnderlying = leverageData.borrowToken.underlying();

        if (borrowUnderlying != token0) {
            if (swapData.call.length == 0) {
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

            // Swap borrow underlying to token0.
            SwapperLib.swapSafe(
                centralRegistry,
                swapData
            );
        }

        // Validate swap was routed into token0, or borrow token was token0.
        uint256 totalAmountA = IERC20(token0).balanceOf(address(this));
        if (totalAmountA == 0) {
            revert PositionManagementVelodromeVolatile__SlippageError();
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

        // Add liquidity to Velodrome lp with volatile params.
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

    function _swapCollateralToBorrowUnderyling(
        DeleverageStruct memory deleverageData
    ) internal virtual override {
        address pool = deleverageData.positionToken.underlying();

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