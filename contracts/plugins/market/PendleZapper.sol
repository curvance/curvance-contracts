// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ZapperBase, ICentralRegistry } from "contracts/plugins/ZapperBase.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract PendleZapper is ZapperBase {
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
    ) ZapperBase(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapAction.inputToken` into Pendle
    ///         market, and enters into Curvance position, for `receiver`.
    /// @dev Requires plugin approval for collateralization.
    /// @param strategyCToken The Curvance token address to enter into a
    ///                       position.
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
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
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
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address router,
        bool isPt,
        PendleLib.PendleData calldata data,
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
            data,
            zapAction.outputToken,
            zapAction.minimumOut
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
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param underlyingToken The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
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
        address router,
        bool isPt,
        address underlyingToken,
        PendleLib.PendleData calldata data,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Pendle market to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapAction.inputToken,
            msg.sender,
            address(this),
            zapAction.inputAmount
        );

        // Exit Pendle position.
        outAmount = _exitPendle(
            router,
            isPt,
            underlyingToken,
            data,
            zapAction,
            swapActions,
            receiver
        );
    }

    /// @notice Withdraws from a Curvance Pendle position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param redeemAction Instructions for a redemption action containing:
    ///                     cToken The address of the cToken corresponding to
    ///                            the redemption action.
    ///                     shares The amount of shares to redeemed.
    ///                     forceRedeemCollateral Whether the collateral
    ///                                           should be always reduced
    ///                                           from caller's collateralized
    ///                                           shares.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
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
        RedeemAction calldata redeemAction,
        address router,
        bool isPt,
        address token,
        PendleLib.PendleData calldata data,
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
            router,
            isPt,
            token,
            data,
            zapAction,
            swapActions,
            receiver
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Withdraws from a Curvance Pendle position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param underlyingToken The underlying token address of the SY.
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
        address router,
        bool isPt,
        address underlyingToken,
        PendleLib.PendleData calldata data,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) internal returns (uint256 outAmount) {
        // Exit Pendle position.
        PendleLib._exitPendle(
            router,
            isPt,
            underlyingToken,
            data,
            zapAction.inputToken,
            zapAction.inputAmount,
            0
        );

        uint256 numTokenSwaps = swapActions.length;
        // Swap unwrapped tokens into `zapAction.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapAction.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }

        outAmount = CommonLib._getBalanceOf(zapAction.outputToken);
        // Validate zap output is sufficient.
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
