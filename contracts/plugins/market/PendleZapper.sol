// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ZapperBase, ICentralRegistry } from "contracts/plugins/ZapperBase.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract PendleZapper is ZapperBase {
    /// TYPES ///

    /// @title Pendle Zapper Data
    /// @param inputToken Address of input token to Zap from.
    /// @param inputAmount The amount of `inputToken` to Zap.
    /// @param outputToken Address of token Zapped into.
    /// @param minimumOut The minimum amount of `outputToken` acceptable
    ///                   from the Zap.
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    struct ZapperData {
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

    /// @notice Swaps then deposits `zapData.inputToken` into Pendle
    ///         market, and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param strategyCToken The Curvance token address to enter into a
    ///                       position.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapData.outputToken`
    ///                       into `strategyCToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param receiver Address that should receive Zapped deposit.
    /// @return outAmount The `strategyCToken` output shares received by
    ///                   `receiver`.
    function enterPendle(
        address strategyCToken,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address router,
        bool isPt,
        PendleLib.PendleData calldata data,
        uint256 expectedShares,
        bool collateralize,
        address receiver
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapData.inputToken,
            zapData.inputAmount,
            swapData,
            zapData.depositAsWrappedNative
        );

        // Enter Pendle position.
        outAmount = PendleLib._enterPendle(
            router,
            isPt,
            data,
            zapData.outputToken,
            zapData.minimumOut
        );

        // Enter Curvance position.
        outAmount = _enterCurvanceSafe(
            strategyCToken,
            zapData.outputToken,
            outAmount,
            expectedShares,
            collateralize,
            receiver
        );
    }

    /// @notice Exits a Pendle market, and zaps it into desired
    ///         token (zapData.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param underlyingToken The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitPendle(
        address router,
        bool isPt,
        address underlyingToken,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Pendle market to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapData.inputToken,
            msg.sender,
            address(this),
            zapData.inputAmount
        );

        // Exit Pendle position.
        outAmount = _exitPendle(
            router,
            isPt,
            underlyingToken,
            data,
            zapData,
            swapData,
            receiver
        );
    }

    /// @notice Withdraws from a Curvance Pendle position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param redemptionData Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the strategyCToken corresponding
    ///                          to Pendle lp token to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitPendle(
        RedemptionData calldata redemptionData,
        address router,
        bool isPt,
        address token,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvanceSafe(
            redemptionData.cToken,
            zapData.inputToken,
            redemptionData.shares,
            zapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            receiver
        );

        // Exit Pendle position.
        outAmount = _exitPendle(
            router,
            isPt,
            token,
            data,
            zapData,
            swapData,
            receiver
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Withdraws from a Curvance Pendle position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param underlyingToken The underlying token address of the SY.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitPendle(
        address router,
        bool isPt,
        address underlyingToken,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address receiver
    ) internal returns (uint256 outAmount) {
        // Exit Pendle position.
        PendleLib._exitPendle(
            router,
            isPt,
            underlyingToken,
            data,
            zapData.inputToken,
            zapData.inputAmount,
            0
        );

        uint256 numTokenSwaps = swapData.length;
        // Swap unwrapped tokens into `zapData.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapData.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib._getTokenBalance(zapData.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapData.minimumOut) {
            revert PendleZapper__SlippageError();
        }

        // Transfer output tokens to `receiver`.
        _transferToRecipient(zapData.outputToken, receiver, outAmount);
    }

    /// @notice Swap `inputToken` into desired underlying tokens.
    /// @param inputToken The input token address.
    /// @param inputAmount The amount of `inputToken` to swap for underlying
    ///                    tokens.
    /// @param swapData Array of swap instruction data
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    function _swapForUnderlyings(
        address inputToken,
        uint256 inputAmount,
        SwapperLib.Swap[] memory swapData,
        bool depositAsWrappedNative
    ) internal {
        _prepareSwap(inputToken, inputAmount, depositAsWrappedNative);

        uint256 numTokenSwaps = swapData.length;
        // Swap `inputToken` into desired underlying tokens.
        for (uint256 i; i < numTokenSwaps; ) {
            if (
                CommonLib._isNative(swapData[i].inputToken) &&
                depositAsWrappedNative
            ) {
                // Switch inputToken to wrapped native token address.
                swapData[i].inputToken = address(wrappedNative);
            }

            // Execute swap into underlying(s).
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }
    }
}
