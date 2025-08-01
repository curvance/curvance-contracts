// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseZapper, ICentralRegistry } from "contracts/plugins/BaseZapper.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract PendleZapper is BaseZapper {
    /// TYPES ///

    /// @param inputToken Address of input token to zap from.
    /// @param inputAmount The amount of `inputToken` to zap.
    /// @param outputToken Address of token to zap into.
    /// @param minimumOut The minimum output amount of `outputToken`
    ///                   acceptable from the zap.
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    struct ZapAction {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 minimumOut;
        bool depositAsWrappedNative;
    }

    /// ERRORS ///

    error PendleZapper__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) BaseZapper(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapAction.inputToken` into Pendle
    ///         market, and enters into Curvance position, for `receiver`.
    /// @dev Requires plugin approval for collateralization.
    /// @param strategyCToken The Curvance token address to enter into a
    ///                       position.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
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
    /// @param zapAction Instructions for a zap action containing:
    ///                  inputToken Address of input token to zap from.
    ///                  inputAmount The amount of `inputToken` to zap.
    ///                  outputToken Address of token to zap into.
    ///                  minimumOut The minimum output amount of `outputToken`
    ///                             acceptable from the zap.
    ///                  depositAsWrappedNative Used when `inputToken` is the
    ///                                         native gas token, indicates
    ///                                         depositing native token into
    ///                                         wrapped version or not.
    /// @param swapActions Array of instructions for swap actions containing:
    ///                    inputToken Address of input token to swap from.
    ///                    inputAmount The amount of `inputToken` to swap.
    ///                    outputToken Address of token to swap into.
    ///                    target Address of the swapper, usually an
    ///                           aggregator.
    ///                    slippage The amount of value-loss acceptable from
    ///                             swapping between tokens.
    ///                    call Swap instruction calldata.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapActions.outputToken`
    ///                       into `strategyCToken` position.
    /// @param collateralizeFor Whether the deposit should be collateralized,
    ///                         requires plugin approval.
    /// @param receiver Address that should receive Zapped deposit.
    /// @return outAmount The `strategyCToken` output shares received by
    ///                   `receiver`.
    function enterPendle(
        address strategyCToken,
        address router,
        bool isPt,
        PendleLib.PendleAction calldata action,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapAction.inputToken,
            zapAction.inputAmount,
            swapActions,
            zapAction.depositAsWrappedNative
        );

        // Enter Pendle position.
        outAmount = PendleLib._enterPendle(
            router,
            isPt,
            zapAction.outputToken,
            zapAction.minimumOut,
            action
        );

        // Enter Curvance position.
        outAmount = _enterCurvanceSafe(
            strategyCToken,
            zapAction.outputToken,
            outAmount,
            expectedShares,
            collateralizeFor,
            receiver
        );
    }

    /// @notice Exits a Pendle market, and zaps it into zapAction.outputToken,
    ///         sending the proceeds to `receiver`.
    /// @param pendleToken The underlying token address of the SY.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
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
    /// @param zapAction Instructions for a zap action containing:
    ///                  inputToken Address of input token to zap from.
    ///                  inputAmount The amount of `inputToken` to zap.
    ///                  outputToken Address of token to zap into.
    ///                  minimumOut The minimum output amount of `outputToken`
    ///                             acceptable from the zap.
    ///                  depositAsWrappedNative Used when `inputToken` is the
    ///                                         native gas token, indicates
    ///                                         depositing native token into
    ///                                         wrapped version or not.
    /// @param swapActions Array of instructions for swap actions containing:
    ///                    inputToken Address of input token to swap from.
    ///                    inputAmount The amount of `inputToken` to swap.
    ///                    outputToken Address of token to swap into.
    ///                    target Address of the swapper, usually an
    ///                           aggregator.
    ///                    slippage The amount of value-loss acceptable from
    ///                             swapping between tokens.
    ///                    call Swap instruction calldata.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitPendle(
        address pendleToken,
        address router,
        bool isPt,
        PendleLib.PendleAction calldata action,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Pendle position to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapAction.inputToken,
            msg.sender,
            address(this),
            zapAction.inputAmount
        );

        // Exit Pendle position.
        outAmount = _exitPendle(
            pendleToken,
            router,
            isPt,
            action,
            zapAction,
            swapActions,
            receiver
        );
    }

    /// @notice Withdraws from a Curvance Pendle position, and zaps it
    ///         into `zapAction.outputToken`.
    /// @param pendleToken The underlying token address of the SY.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
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
    /// @param redeemAction Instructions for a redemption action containing:
    ///                     cToken The address of the cToken corresponding to
    ///                            the redemption action.
    ///                     shares The amount of shares to redeemed.
    ///                     forceRedeemCollateral Whether the collateral
    ///                                           should be always reduced
    ///                                           from caller's collateralized
    ///                                           shares.
    /// @param zapAction Instructions for a zap action containing:
    ///                  inputToken Address of input token to zap from.
    ///                  inputAmount The amount of `inputToken` to zap.
    ///                  outputToken Address of token to zap into.
    ///                  minimumOut The minimum output amount of `outputToken`
    ///                             acceptable from the zap.
    ///                  depositAsWrappedNative Used when `inputToken` is the
    ///                                         native gas token, indicates
    ///                                         depositing native token into
    ///                                         wrapped version or not.
    /// @param swapActions Array of instructions for swap actions containing:
    ///                    inputToken Address of input token to swap from.
    ///                    inputAmount The amount of `inputToken` to swap.
    ///                    outputToken Address of token to swap into.
    ///                    target Address of the swapper, usually an
    ///                           aggregator.
    ///                    slippage The amount of value-loss acceptable from
    ///                             swapping between tokens.
    ///                    call Swap instruction calldata.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitPendle(
        address pendleToken,
        address router,
        bool isPt,
        PendleLib.PendleAction calldata action,
        RedeemAction calldata redeemAction,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvanceSafe(
            redeemAction.cToken,
            zapAction.inputToken,
            redeemAction.shares,
            zapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            receiver
        );

        // Exit Pendle position.
        outAmount = _exitPendle(
            pendleToken,
            router,
            isPt,
            action,
            zapAction,
            swapActions,
            receiver
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Withdraws from a Curvance Pendle position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param pendleToken The underlying token address of the SY.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
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
    /// @param zapAction Instructions for a zap action containing:
    ///                  inputToken Address of input token to zap from.
    ///                  inputAmount The amount of `inputToken` to zap.
    ///                  outputToken Address of token to zap into.
    ///                  minimumOut The minimum output amount of `outputToken`
    ///                             acceptable from the zap.
    ///                  depositAsWrappedNative Used when `inputToken` is the
    ///                                         native gas token, indicates
    ///                                         depositing native token into
    ///                                         wrapped version or not.
    /// @param swapActions Array of instructions for swap actions containing:
    ///                    inputToken Address of input token to swap from.
    ///                    inputAmount The amount of `inputToken` to swap.
    ///                    outputToken Address of token to swap into.
    ///                    target Address of the swapper, usually an
    ///                           aggregator.
    ///                    slippage The amount of value-loss acceptable from
    ///                             swapping between tokens.
    ///                    call Swap instruction calldata.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitPendle(
        address pendleToken,
        address router,
        bool isPt,
        PendleLib.PendleAction calldata action,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) internal returns (uint256 outAmount) {
        // Exit Pendle position.
        PendleLib._exitPendle(
            router,
            isPt,
            zapAction.inputToken,
            0,
            action,
            pendleToken,
            zapAction.inputAmount
        );

        uint256 numTokenSwaps = swapActions.length;
        // Swap unwrapped tokens into `zapAction.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }

        outAmount = CommonLib._getBalanceOf(zapAction.outputToken);
        // Validate action output is sufficient.
        if (outAmount < zapAction.minimumOut) {
            revert PendleZapper__SlippageError();
        }

        // Transfer output tokens to `receiver`.
        _transferToRecipient(zapAction.outputToken, receiver, outAmount);
    }

    /// @notice Swap `inputToken` into desired underlying tokens.
    /// @param inputToken The input token address.
    /// @param inputAmount The amount of `inputToken` to swap for underlying
    ///                    tokens.
    /// @param swapActions Array of instructions for swap actions containing:
    ///                    inputToken Address of input token to swap from.
    ///                    inputAmount The amount of `inputToken` to swap.
    ///                    outputToken Address of token to swap into.
    ///                    target Address of the swapper, usually an
    ///                           aggregator.
    ///                    slippage The amount of value-loss acceptable from
    ///                             swapping between tokens.
    ///                    call Swap instruction calldata.
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    function _swapForUnderlyings(
        address inputToken,
        uint256 inputAmount,
        SwapperLib.Swap[] memory swapActions,
        bool depositAsWrappedNative
    ) internal {
        _prepareSwap(inputToken, inputAmount, depositAsWrappedNative);

        uint256 numTokenSwaps = swapActions.length;
        // Swap `inputToken` into desired underlying tokens.
        for (uint256 i; i < numTokenSwaps; ) {
            if (
                CommonLib._isNative(swapActions[i].inputToken) &&
                depositAsWrappedNative
            ) {
                // Switch inputToken to wrapped native token address.
                swapActions[i].inputToken = address(wrappedNative);
            }

            // Execute swap into underlying(s).
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }
    }
}
