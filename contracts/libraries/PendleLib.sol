// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IPendleRouter, ApproxParams, TokenInput, TokenOutput, LimitOrderData } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

library PendleLib {
    /// TYPES ///

    struct PendleData {
        ApproxParams approx;
        TokenInput input;
        TokenOutput output;
        LimitOrderData limit;
    }

    /// FUNCTIONS ///

    /// @notice Enter a Pendle position.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param lpToken The Pendle lp token address.
    /// @param minOutAmount The minimum lp/pt output amount acceptable.
    /// @return outAmount The lp/pt output amount of Pendle lp received.
    function enterPendle(
        address router,
        bool isPt,
        PendleData memory data,
        address lpToken,
        uint256 minOutAmount
    ) internal returns (uint256 outAmount) {
        if (isPt) {
            // swap input token to pt
            SwapperLib._approveTokenIfNeeded(
                data.input.tokenIn,
                address(router),
                data.input.netTokenIn
            );
            (outAmount, , ) = IPendleRouter(router).swapExactTokenForPt(
                address(this),
                lpToken,
                minOutAmount,
                data.approx,
                data.input,
                data.limit
            );
        } else {
            (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();
            address[] memory tokens = sy.getTokensIn();
            uint256 numTokens = tokens.length;
            address token;
            uint256 balance;

            for (uint256 i = 0; i < numTokens; ++i) {
                token = tokens[i];

                if (token == address(0)) {
                    balance = address(this).balance;

                    if (balance > 0) {
                        sy.deposit{ value: balance }(
                            address(this),
                            token,
                            balance,
                            0
                        );
                    }
                } else {
                    balance = IERC20(token).balanceOf(address(this));

                    if (balance > 0) {
                        SwapperLib._approveTokenIfNeeded(
                            token,
                            address(sy),
                            balance
                        );
                        sy.deposit(address(this), token, balance, 0);
                    }
                }
            }

            balance = sy.balanceOf(address(this));
            SwapperLib._approveTokenIfNeeded(address(sy), router, balance);

            // Add liquidity to Pendle lp via SY.
            (outAmount, ) = IPendleRouter(router).addLiquiditySingleSy(
                address(this),
                lpToken,
                balance,
                minOutAmount,
                data.approx,
                data.limit
            );
        }
    }

    /// @notice Exit a Pendle position.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token If isPt= false then the underlying token address of the SY, if not then the PT address.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param lpToken The Pendle lp token address.
    /// @param amount The Pendle lp/pt amount to exit.
    /// @param minSyOut The minimum SY output amount acceptable.
    /// @param minTokenOut The minimum token output amount acceptable.
    function exitPendle(
        address router,
        bool isPt,
        address token,
        PendleData memory data,
        address lpToken,
        uint256 amount,
        uint256 minSyOut,
        uint256 minTokenOut
    ) internal {
        if (isPt) {
            SwapperLib._approveTokenIfNeeded(token, router, amount);

            IPendleRouter(router).swapExactPtForToken(
                address(this),
                lpToken,
                amount,
                data.output,
                data.limit
            );
        } else {
            SwapperLib._approveTokenIfNeeded(lpToken, router, amount);

            (uint256 balance, ) = IPendleRouter(router)
                .removeLiquiditySingleSy(
                    address(this),
                    lpToken,
                    amount,
                    minSyOut,
                    data.limit
                );

            (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();
            sy.redeem(address(this), balance, token, minTokenOut, false);
        }
    }
}
