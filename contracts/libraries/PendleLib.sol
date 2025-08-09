// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IPendleRouter, ApproxParams, TokenInput, TokenOutput, LimitOrderData } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @title Curvance Pendle Library.
/// @notice Helper Library for working with Pendle tokens. Supports both
///         creating and exiting positions for better composability.
library PendleLib {
    /// TYPES ///

    /// @notice Instructions for a Pendle action.
    /// @param approx The approximate price parameters for the Pendle swap.
    /// @param input Represents the input parameters for token operations
    ///              within the Pendle protocol. Users start with `netTokenIn`
    ///              amount of `tokenIn`. If `tokenIn` differs from
    ///              `tokenMintSy`, a swap is performed using the specified
    ///              aggregator to convert `tokenIn` to `tokenMintSy`, which
    ///              is then used to mint SY tokens.
    /// @param output Represents the output parameters for token operations
    ///               within the Pendle protocol. Users receive SY tokens,
    ///               redeem them to `tokenRedeemSy`, and may use an
    ///               aggregator to swap `tokenRedeemSy` to the desired
    ///               `tokenOut`.
    /// @param limit Contains parameters for executing limit orders within
    ///              the Pendle protocol.
    struct PendleAction {
        ApproxParams approx;
        TokenInput input;
        TokenOutput output;
        LimitOrderData limit;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Enters a Pendle position.
    /// @param router The Pendle router address to use on action.
    /// @param isPt Whether pendle token is PT or not.
    /// @param lpToken The Pendle lp token address.
    /// @param minOutAmount The minimum output amount acceptable.
    /// @param action Instructions for a Pendle action containing:
    ///               approx The approximate price parameters for the Pendle
    ///                      swap.
    ///               input Represents the input parameters for a Pendle
    ///                     action. Users start with `netTokenIn` amount of
    ///                     `tokenIn`. If `tokenIn` differs from
    ///                     `tokenMintSy`, a swap is performed using the
    ///                     specified aggregator to convert `tokenIn` to
    ///                     `tokenMintSy`, which is then used to mint SY
    ///                     tokens.
    ///               output Represents the output parameters for a Pendle
    ///                      action. Users receive SY tokens, redeem them
    ///                      to `tokenRedeemSy`, and may use an aggregator
    ///                      to swap `tokenRedeemSy` to the desired
    ///                      `tokenOut`.
    ///               limit Contains parameters for executing limit orders.
    /// @return outAmount The lp/pt output amount of Pendle lp received.
    function _enterPendle(
        address router,
        bool isPt,
        address lpToken,
        uint256 minOutAmount,
        PendleAction memory action
    ) internal returns (uint256 outAmount) {
        if (isPt) {
            // Swap `tokenIn` to principal token.
            SwapperLib._approveIfNeeded(
                action.input.tokenIn,
                address(router),
                action.input.netTokenIn
            );
            (outAmount,, ) = IPendleRouter(router).swapExactTokenForPt(
                address(this),
                lpToken,
                minOutAmount,
                action.approx,
                action.input,
                action.limit
            );
        } else {
            (IStandardizedYield sy,, ) = IPMarket(lpToken).readTokens();
            address[] memory tokens = sy.getTokensIn();
            uint256 numTokens = tokens.length;
            address token;
            uint256 balance;

            for (uint256 i; i < numTokens; ++i) {
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
                        SwapperLib._approveIfNeeded(
                            token,
                            address(sy),
                            balance
                        );
                        sy.deposit(address(this), token, balance, 0);
                    }
                }
            }

            balance = sy.balanceOf(address(this));
            SwapperLib._approveIfNeeded(address(sy), router, balance);

            // Add liquidity to Pendle lp via SY.
            (outAmount, ) = IPendleRouter(router).addLiquiditySingleSy(
                address(this),
                lpToken,
                balance,
                minOutAmount,
                action.approx,
                action.limit
            );
        }
    }

    /// @notice Exits a Pendle position.
    /// @param router The Pendle router address to use on action.
    /// @param isPt Whether pendle token is PT or not.
    /// @param lpToken The Pendle lp token address.
    /// @param minOutAmount The minimum output amount acceptable.
    /// @param action Instructions for a Pendle action containing:
    ///               router The Pendle router address to use on action.
    ///               isPt Whether pendle token is PT or not.
    ///               approx The approximate price parameters for the Pendle
    ///                      swap.
    ///               input Represents the input parameters for a Pendle
    ///                     action. Users start with `netTokenIn` amount of
    ///                     `tokenIn`. If `tokenIn` differs from
    ///                     `tokenMintSy`, a swap is performed using the
    ///                     specified aggregator to convert `tokenIn` to
    ///                     `tokenMintSy`, which is then used to mint SY
    ///                     tokens.
    ///               output Represents the output parameters for a Pendle
    ///                      action. Users receive SY tokens, redeem them
    ///                      to `tokenRedeemSy`, and may use an aggregator
    ///                      to swap `tokenRedeemSy` to the desired
    ///                      `tokenOut`.
    ///               limit Contains parameters for executing limit orders.
    /// @param pendleToken If isPt = false then the underlying token address
    ///                    of the SY, if not then the PT address.
    /// @param amount The Pendle lp/pt amount to exit.
    function _exitPendle(
        address router,
        bool isPt,
        address lpToken,
        uint256 minOutAmount,
        PendleAction memory action,
        address pendleToken,
        uint256 amount
    ) internal {
        if (isPt) {
            SwapperLib._approveIfNeeded(pendleToken, router, amount);

            IPendleRouter(router).swapExactPtForToken(
                address(this),
                lpToken,
                amount,
                action.output,
                action.limit
            );
        } else {
            SwapperLib._approveIfNeeded(lpToken, router, amount);

            (uint256 balance, ) = IPendleRouter(router)
                .removeLiquiditySingleSy(
                    address(this),
                    lpToken,
                    amount,
                    0,
                    action.limit
                );

            (IStandardizedYield sy,, ) = IPMarket(lpToken).readTokens();
            sy.redeem(address(this), balance, pendleToken, minOutAmount, false);
        }
    }
}
