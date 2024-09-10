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
    /// @param lpToken The Pendle lp/pt token address.
    /// @param lpMinOutAmount The minimum output amount acceptable.
    /// @return lpOutAmount The output amount of Pendle lp received.
    function enterPendle(
        address router,
        bool isPt,
        PendleData calldata data,
        address lpToken,
        uint256 lpMinOutAmount
    ) internal returns (uint256 lpOutAmount) {
        if (isPt) {
            // Add liquidity to Pendle lp via SY.
            (lpOutAmount, , ) = IPendleRouter(router).swapExactTokenForPt(
                address(this),
                lpToken,
                lpMinOutAmount,
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
            (lpOutAmount, ) = IPendleRouter(router).addLiquiditySingleSy(
                address(this),
                lpToken,
                balance,
                lpMinOutAmount,
                data.approx,
                data.limit
            );
        }
    }

    /// @notice Exit a Pendle position.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param lpToken The Pendle lp token address.
    /// @param lpAmount The Pendle lp amount to exit.
    function exitPendle(
        address router,
        bool isPt,
        address token,
        PendleData calldata data,
        address lpToken,
        uint256 lpAmount
    ) internal {
        SwapperLib._approveTokenIfNeeded(lpToken, router, lpAmount);

        if (isPt) {
            IPendleRouter(router).swapExactPtForToken(
                address(this),
                lpToken,
                lpAmount,
                data.output,
                data.limit
            );
        } else {
            (uint256 balance, ) = IPendleRouter(router)
                .removeLiquiditySingleSy(
                    address(this),
                    lpToken,
                    lpAmount,
                    0,
                    data.limit
                );

            (IStandardizedYield sy, , ) = IPMarket(lpToken).readTokens();
            sy.redeem(address(this), balance, token, 0, false);
        }
    }
}
