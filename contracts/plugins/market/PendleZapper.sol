// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PendleZapperMinimal } from "contracts/plugins/market/PendleZapperMinimal.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

/// @title Curvance Pendle Zapper.
/// @notice Pendle Asset-specific contract for executing zap related
///         actions.
/// @dev Curvance zapper contracts enshrine actions that
///      usually would require multiple sequential actions to facilitate,
///      specifically swapping, depositing, redemptions, and repayments.
///
///      Curvance token contracts facilitate these operations through our
///      standard contract interfaces and the plugin system.
///
///      Actions that include collateralization require plugin approval to the
///      corresponding zapper contract, to collateralize on behalf of another
///      user via a zapper both the zapper and the caller must have plugin
///      approval from the account being collateralized on behalf of.
///
///      The "Pendle" contract is the zapper for working with Pendle native
///      erc20 tokens such as sUSDe/sUSDe-PT-dec-31-2025 LP tokens,
///      or sUSDe-PT-dec-31-2025 PT tokens.
///
contract PendleZapper is PendleZapperMinimal {
    /// ERRORS ///
    error PendleZapper__SlippageError();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address wNative
    ) PendleZapperMinimal(cr, wNative) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Exits a Pendle market, and zaps it into zapAction.outputToken,
    ///         sending the proceeds to `receiver`.
    /// @param pendleToken The token being exited: PT when `isPt` is true,
    ///                    otherwise the SY redeem token.
    /// @param router The Pendle router address.
    /// @param pendleMarket The Pendle market used to exit the position.
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
        address pendleMarket,
        bool isPt,
        PendleLib.PendleAction calldata action,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        if (receiver == address(0)) {
            revert BaseZapper__ExecutionError();
        }

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
            pendleMarket,
            isPt,
            action,
            zapAction,
            swapActions,
            receiver
        );
    }

    /// @notice Withdraws from a Curvance Pendle position, and zaps it
    ///         into `zapAction.outputToken`.
    /// @param pendleToken The token being exited: PT when `isPt` is true,
    ///                    otherwise the SY redeem token.
    /// @param router The Pendle router address.
    /// @param pendleMarket The Pendle market used to exit the position.
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
        address pendleMarket,
        bool isPt,
        PendleLib.PendleAction calldata action,
        RedeemAction calldata redeemAction,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        if (receiver == address(0)) {
            revert BaseZapper__ExecutionError();
        }

        // Exit Curvance position.
        _exitCurvance(
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
            pendleMarket,
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
    /// @param pendleToken The token being exited: PT when `isPt` is true,
    ///                    otherwise the SY redeem token.
    /// @param router The Pendle router address.
    /// @param pendleMarket The Pendle market used to exit the position.
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
        address pendleMarket,
        bool isPt,
        PendleLib.PendleAction calldata action,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) internal returns (uint256 outAmount) {
        if (zapAction.minimumOut == 0) {
            revert PendleZapper__SlippageError();
        }

        if (isPt) {
            if (pendleToken != zapAction.inputToken) {
                revert BaseZapper__ExecutionError();
            }
        } else if (pendleMarket != zapAction.inputToken) {
            revert BaseZapper__ExecutionError();
        }

        // Exit Pendle position.
        PendleLib._exitPendle(
            router,
            isPt,
            pendleMarket,
            0,
            action,
            pendleToken,
            zapAction.inputAmount
        );

        uint256 numTokenSwaps = swapActions.length;
        // Swap unwrapped tokens into `zapAction.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            SwapperLib._swapSafe(centralRegistry, swapActions[i++]);
        }

        outAmount = CommonLib._balanceOf(zapAction.outputToken);
        // Validate action output is sufficient.
        if (outAmount < zapAction.minimumOut) {
            revert PendleZapper__SlippageError();
        }

        // Transfer output tokens to `receiver`.
        _transferToRecipient(zapAction.outputToken, receiver, outAmount);
    }
}
