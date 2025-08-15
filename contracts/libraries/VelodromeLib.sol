// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { BPS, WAD } from "contracts/libraries/ConstantsLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";

/// @title Curvance Velodrome Library.
/// @notice Helper Library for working with Velodrome LP tokens. Supports both
///         creating and exiting LP positions for better composability.
///         NOTE: This library does not currently support slipstream LPs at
///               this time, but may in the future.
library VelodromeLib {
    /// ERRORS ///

    error VelodromeLib__ReceivedAmountIsLessThanMinimum(
        uint256 amount,
        uint256 minimum
    );

    /// CONSTANTS ///

    /// @notice Maximum slippage allowed for Velodrome add liquidity call.
    /// @dev Usually you would not want to hardcode a % slippage value but we
    ///      check lp output amount with a minimum afterwards, so the native
    ///      add liquidity slippage check is semi redundant.
    ///      100 = 1%.
    uint256 public constant VELODROME_ADD_LIQUIDITY_SLIPPAGE = 100;

    /// INTERNAL FUNCTIONS ///

    /// @notice Enters a Velodrome position based on parameters.
    /// @param router The Velodrome router address to enter through.
    /// @param factory The Velodrome factory address.
    /// @param lpToken The Velodrome lp token address to enter.
    /// @param amount0 The amount of `token0` to enter through.
    /// @param amount1 The amount of `token1`to enter through.
    /// @param lpMinOutAmount The minimum output amount of `lpToken` that is
    ///                       acceptable for execution.
    /// @return lpOutAmount The amount of `lpToken` received.
    function _enterVelodrome(
        address router,
        address factory,
        address lpToken,
        uint256 amount0,
        uint256 amount1,
        uint256 lpMinOutAmount
    ) internal returns (uint256 lpOutAmount) {
        address token0 = IVeloPair(lpToken).token0();
        address token1 = IVeloPair(lpToken).token1();
        bool stable = IVeloPool(lpToken).stable();

        // Check if we are entering through token0 leg.
        if (amount0 > 0) {
            (uint256 r0, uint256 r1, ) = IVeloPair(lpToken).getReserves();
            // Calculate optimal swap amount to end with 50/50 split.
            uint256 swapAmount = _optimalDeposit(
                factory,
                lpToken,
                amount0,
                r0,
                r1,
                10 ** IERC20(token0).decimals(),
                10 ** IERC20(token1).decimals(),
                stable
            );

            // Swap token0 into token1.
            amount1 = _swapExactTokensForTokens(
                router,
                lpToken,
                token0,
                token1,
                swapAmount,
                stable
            );
            amount0 -= swapAmount;

            // Enter Velodrome position.
            uint256 newLpOutAmount = _addLiquidity(
                router,
                token0,
                token1,
                stable,
                amount0,
                amount1,
                VELODROME_ADD_LIQUIDITY_SLIPPAGE
            );

            lpOutAmount += newLpOutAmount;
        }

        amount1 = CommonLib._balanceOf(token1);

        // Check if we are entering through token1 leg.
        if (amount1 > 0) {
            (uint256 r0, uint256 r1, ) = IVeloPair(lpToken).getReserves();
            // Calculate optimal swap amount to end with 50/50 split.
            uint256 swapAmount = _optimalDeposit(
                factory,
                lpToken,
                amount1,
                r1,
                r0,
                10 ** IERC20(token1).decimals(),
                10 ** IERC20(token0).decimals(),
                stable
            );

            // Swap `token1` into `token0`.
            amount0 = _swapExactTokensForTokens(
                router,
                lpToken,
                token1,
                token0,
                swapAmount,
                stable
            );
            amount1 -= swapAmount;

            // Enter Velodrome position.
            uint256 newLpOutAmount = _addLiquidity(
                router,
                token0,
                token1,
                stable,
                amount0,
                amount1,
                VELODROME_ADD_LIQUIDITY_SLIPPAGE
            );

            lpOutAmount += newLpOutAmount;
        }

        // Validate we got an acceptable amount of Velodrome lp tokens.
        if (lpOutAmount < lpMinOutAmount) {
            revert VelodromeLib__ReceivedAmountIsLessThanMinimum(
                lpOutAmount,
                lpMinOutAmount
            );
        }
    }

    /// @notice Exits a Velodrome position based on parameters.
    /// @param router The Velodrome router address to exit through.
    /// @param lpToken The Velodrome lp token address to exit.
    /// @param lpAmount The amount of `lpToken` to exit.
    function _exitVelodrome(
        address router,
        address lpToken,
        uint256 lpAmount
    ) internal {
        address token0 = IVeloPair(lpToken).token0();
        address token1 = IVeloPair(lpToken).token1();
        bool stable = IVeloPool(lpToken).stable();

        // Approve Velodrome lp token.
        SwapperLib._approveIfNeeded(lpToken, router, lpAmount);

        // Exit Velodrome position.
        IVeloRouter(router).removeLiquidity(
            token0,
            token1,
            stable,
            lpAmount,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    /// @notice Adds liquidity in `token0` and `token1` into a Velodrome
    ///         liquidity pool.
    /// @param router The Velodrome router address to add liquidity through.
    /// @param token0 The first token of the pair to add liquidity in.
    /// @param token1 The second token of the pair to add liquidity in.
    /// @param stable Whether the Velodrome lp token is stable or volatile.
    /// @param amount0 The amount of `token0` to add as liquidity.
    /// @param amount1 The amount of `token1` to add as liquidity.
    /// @param slippage The maximum percentage slippage to allow,
    ///                 in `basis points`.
    /// @return liquidity The amount of LP tokens received from adding
    ///                   liquidity.
    function _addLiquidity(
        address router,
        address token0,
        address token1,
        bool stable,
        uint256 amount0,
        uint256 amount1,
        uint256 slippage
    ) internal returns (uint256 liquidity) {
        // Approve Router to take token0 and token1.
        SwapperLib._approveIfNeeded(token0, router, amount0);
        SwapperLib._approveIfNeeded(token1, router, amount1);

        // Deposit liquidity into Velodrome.
        (, , liquidity) = IVeloRouter(router).addLiquidity(
            token0,
            token1,
            stable,
            amount0,
            amount1,
            amount0 - (amount0 * slippage) / BPS,
            amount1 - (amount1 * slippage) / BPS,
            address(this),
            block.timestamp
        );

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(token0, router);
        SwapperLib._removeApprovalIfNeeded(token1, router);
    }

    /// @notice Calculates the optimal amount of Token0 to swap to Token1
    ///         for a perfect LP deposit for a stable pair.
    /// @param factory The Velodrome factory address.
    /// @param lpToken The Velodrome lp token address.
    /// @param amount0 The amount of `token0` this vault has currently.
    /// @param reserve0 The amount of `token0` the LP has in reserve.
    /// @param reserve1 The amount of `token1` the LP has in reserve.
    /// @param decimals0 The decimals of `token0`.
    /// @param decimals1 The decimals of `token1`.
    /// @param stable Whether the Velodrome lp token is stable or volatile.
    /// @return The optimal amount of Token0 to swap.
    function _optimalDeposit(
        address factory,
        address lpToken,
        uint256 amount0,
        uint256 reserve0,
        uint256 reserve1,
        uint256 decimals0,
        uint256 decimals1,
        bool stable
    ) internal view returns (uint256) {
        // Cache swap fee from pair factory.
        uint256 swapFee = IVeloPairFactory(factory).getFee(lpToken, stable);
        uint256 a;

        // sAMM deposit calculation.
        if (stable) {
            a =
                (((amount0 * BPS) / (BPS - swapFee)) * WAD) /
                decimals0;

            uint256 x = (reserve0 * WAD) / decimals0;
            uint256 y = (reserve1 * WAD) / decimals1;
            uint256 x2 = (x * x) / WAD;
            uint256 y2 = (y * y) / WAD;
            uint256 p = (y * (((x2 * 3 + y2) * WAD) / (y2 * 3 + x2))) / x;

            uint256 num = a * y;
            uint256 den = ((a + x) * p) / WAD + y;

            return ((num / den) * decimals0) / WAD;
        }

        // vAMM deposit calculation.
        uint256 swapFeeFactor = BPS - swapFee;

        a = (BPS + swapFeeFactor) * reserve0;
        uint256 b = amount0 * BPS * reserve0 * 4 * swapFeeFactor;
        uint256 c = FixedPointMathLib.sqrt(a * a + b);
        uint256 d = swapFeeFactor * 2;
        return (c - a) / d;
    }

    /// @notice Swaps amount of `tokenIn` into `tokenOut`.
    /// @param router The Velodrome router address.
    /// @param lpToken The Velodrome lp token address.
    /// @param tokenIn The token to be swapped from.
    /// @param tokenOut The token to be swapped into.
    /// @param amount The amount of `tokenIn` to be swapped.
    /// @param stable Whether the Velodrome lp token is stable or volatile.
    /// @return The amount of `tokenOut` received from the swap.
    function _swapExactTokensForTokens(
        address router,
        address lpToken,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool stable
    ) internal returns (uint256) {
        // Approve Router to take `tokenIn`.
        SwapperLib._approveIfNeeded(tokenIn, router, amount);

        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = tokenIn;
        routes[0].to = tokenOut;
        routes[0].stable = stable;
        routes[0].factory = IVeloPool(lpToken).factory();

        // Swap `tokenIn` into `tokenOut`.
        uint256[] memory amountsOut = IVeloRouter(router)
            .swapExactTokensForTokens(
                amount,
                0,
                routes,
                address(this),
                block.timestamp
            );

        // Remove any excess approval.
        SwapperLib._removeApprovalIfNeeded(tokenIn, router);

        return amountsOut[amountsOut.length - 1];
    }
}
