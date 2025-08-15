// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { BaseZapper, ICentralRegistry } from "contracts/plugins/BaseZapper.sol";

import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";

contract VelodromeZapper is BaseZapper {
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

    error VelodromeZapper__SlippageError();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr, address wNative) BaseZapper(cr, wNative) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapAction.inputToken`, into Velodrome,
    ///         and enters into a Curvance position, for `receiver`.
    /// @dev Requires plugin approval for collateralization.
    /// @param strategyCToken The Curvance token address to enter a
    ///                       position in.
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
    /// @param router The Velodrome router address.
    /// @param factory The Velodrome factory address.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of
    ///                       `swapActions.outputToken` into `strategyCToken`
    ///                       position.
    /// @param collateralizeFor Whether the deposit should be collateralized,
    ///                         requires plugin approval.
    /// @param receiver Address that should receive Zapped deposit.
    /// @return outAmount The `strategyCToken` output shares received by
    ///                   `receiver`.
    function enterVelodrome(
        address strategyCToken,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address router,
        address factory,
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

        // Enter Velodrome position.
        outAmount = VelodromeLib._enterVelodrome(
            router,
            factory,
            zapAction.outputToken,
            CommonLib._balanceOf(IVeloPair(zapAction.outputToken).token0()),
            CommonLib._balanceOf(IVeloPair(zapAction.outputToken).token1()),
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

    /// @notice Exits a Velodrome position, and zaps it into desired
    ///         token (zapAction.outputToken).
    /// @param router The Velodrome router address.
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
    function exitVelodrome(
        address router,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Velodrome sAMM/vAMM LP to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapAction.inputToken,
            msg.sender,
            address(this),
            zapAction.inputAmount
        );

        // Exit Velodrome position.
        outAmount = _exitVelodrome(router, zapAction, swapActions, receiver);
    }

    /// @notice Withdraws from a Curvance Velodrome position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param redeemAction Instructions for a redemption action containing:
    ///                     cToken The address of the cToken corresponding to
    ///                            the redemption action.
    ///                     shares The amount of shares to redeemed.
    ///                     forceRedeemCollateral Whether the collateral
    ///                                           should be always reduced
    ///                                           from caller's collateralized
    ///                                           shares.
    /// @param router The Velodrome router address.
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
    function redeemAndExitVelodrome(
        RedeemAction calldata redeemAction,
        address router,
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

        // Exit Velodrome position.
        outAmount = _exitVelodrome(router, zapAction, swapActions, receiver);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Withdraws from a Curvance Velodrome position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param router The Velodrome router address.
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
    function _exitVelodrome(
        address router,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address receiver
    ) internal returns (uint256 outAmount) {
        // Exit Velodrome position.
        VelodromeLib._exitVelodrome(
            router,
            zapAction.inputToken,
            zapAction.inputAmount
        );

        uint256 numTokenSwaps = swapActions.length;
        // Swap unwrapped tokens into `zapAction.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapAction.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }

        outAmount = CommonLib._balanceOf(zapAction.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapAction.minimumOut) {
            revert VelodromeZapper__SlippageError();
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
