// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseZapper, ICentralRegistry } from "contracts/plugins/BaseZapper.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

/// @title Curvance Minimal Pendle Zapper.
/// @notice Pendle zapper variant restricted to entering Curvance Pendle
///         positions.
/// @dev This contract intentionally omits Pendle exit and redeem-and-exit
///      flows so launch deployments can register the smallest useful zapper
///      surface.
contract PendleZapperMinimal is BaseZapper {
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

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address wNative
    ) BaseZapper(cr, wNative) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapAction.inputToken` into Pendle
    ///         market, and enters into Curvance position, for `receiver`.
    /// @dev Requires plugin approval for collateralization.
    /// @param cToken The Curvance token address to enter into a position.
    /// @param router The Pendle router address.
    /// @param pendleMarket The Pendle market used to enter the position.
    /// @param isPt Whether `zapAction.outputToken` is a PT or not.
    /// @param action Instructions for a Pendle action.
    /// @param zapAction Instructions for a zap action.
    /// @param swapActions Array of pre-Pendle swap instructions.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing into `cToken`.
    /// @param collateralizeFor Whether the deposit should be collateralized,
    ///                         requires plugin approval.
    /// @param receiver Address that should receive Zapped deposit.
    /// @return outAmount The `cToken` output shares received by `receiver`.
    function enterPendle(
        address cToken,
        address router,
        address pendleMarket,
        bool isPt,
        PendleLib.PendleAction calldata action,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Redundant receiver == address(0) check so we fail fast if execution
        // is impossible.
        if (receiver == address(0) || expectedShares == 0) {
            revert BaseZapper__ExecutionError();
        }

        address pendleToken = zapAction.outputToken;

        _checkAddresses(cToken, pendleToken);

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
            pendleMarket,
            zapAction.minimumOut,
            action,
            pendleToken
        );

        // Enter Curvance position.
        outAmount = _enterCurvance(
            cToken,
            pendleToken,
            outAmount,
            expectedShares,
            collateralizeFor,
            receiver
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Swap `inputToken` into desired underlying tokens.
    /// @param inputToken The input token address.
    /// @param inputAmount The amount of `inputToken` to swap for underlying
    ///                    tokens.
    /// @param swapActions Array of pre-Pendle swap instructions.
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
        // Swap `inputToken` into desired underlying(s).
        for (uint256 i; i < numTokenSwaps; ) {
            if (
                CommonLib._isNative(swapActions[i].inputToken) &&
                depositAsWrappedNative
            ) {
                // Switch inputToken to wrapped native token address.
                swapActions[i].inputToken = address(wrappedNative);
            }

            // Execute swap into underlying(s).
            SwapperLib._swapSafe(centralRegistry, swapActions[i++]);
        }
    }
}
