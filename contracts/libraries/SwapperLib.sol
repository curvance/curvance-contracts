// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { LowLevelCallsHelper } from "contracts/libraries/LowLevelCallsHelper.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { NO_ERROR, WAD } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IExternalCalldataChecker } from "contracts/interfaces/IExternalCalldataChecker.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";

/// @title Curvance Swapper Library.
/// @notice Helper Library for performing composable swaps with varying
///         degrees of slippage tolerance. "Unsafe" swaps perform a standard
///         slippage check whereas "safe" swaps not only check for standard
///         slippage but also check against the Oracle Manager's prices as
///         well.
///         NOTE: This library does not intend to provide support for fee on
///               transfer tokens though support may be built in the future.
library SwapperLib {
    /// TYPES ///

    /// @notice Instructions to execute a swap, selling `inputToken` for
    ///         `outputToken`.
    /// @param inputToken Address of input token to swap from.
    /// @param inputAmount The amount of `inputToken` to swap.
    /// @param outputToken Address of token to swap into.
    /// @param target Address of the swapper, usually an aggregator.
    /// @param slippage The amount of value-loss acceptable from swapping
    ///                 between tokens.
    /// @param call Swap instruction calldata.
    struct Swap {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        address target;
        uint256 slippage;
        bytes call;
    }

    /// ERRORS ///

    error SwapperLib__UnknownCalldata();
    error SwapperLib__TokenPrice(address inputToken);
    error SwapperLib__Slippage(uint256 slippage);

    /// INTERNAL FUNCTIONS ///

    /// @notice Swaps `action.inputToken` into a `action.outputToken`
    ///         without an extra slippage check.
    /// @param cr The address of the Protocol Central Registry to pull
    ///           addresses from.
    /// @param action Instructions for a swap action containing:
    ///               inputToken Address of input token to swap from.
    ///               inputAmount The amount of `inputToken` to swap.
    ///               outputToken Address of token to swap into.
    ///               target Address of the swapper, usually an aggregator.
    ///               slippage The amount of value-loss acceptable from
    ///                        swapping between tokens.
    ///               call Swap instruction calldata.
    /// @return outAmount The output amount received from swapping.
    function _swapUnsafe(
        ICentralRegistry cr,
        Swap memory action
    ) internal returns (uint256 outAmount) {
        address callDataChecker = cr.externalCalldataChecker(action.target);

        // Validate we know how to verify this calldata.
        if (callDataChecker == address(0)) {
            revert SwapperLib__UnknownCalldata();
        }

        // Verify calldata integrity.
        IExternalCalldataChecker(callDataChecker)
            .checkCalldata(action, address(this));

        // Approve `action.inputToken` to target contract, if necessary.
        _approveIfNeeded(action.inputToken, action.target, action.inputAmount);

        // Cache output token from struct for easier querying.
        address outputToken = action.outputToken;
        uint256 balanceBefore = CommonLib._getBalanceOf(outputToken);

        uint256 callValue = CommonLib._isNative(action.inputToken) ?
            action.inputAmount : 0;

        // Execute the swap.
        LowLevelCallsHelper._callWithNative(
            action.target,
            action.call,
            callValue
        );

        // Remove any excess approval.
        _removeApprovalIfNeeded(action.inputToken, action.target);

        outAmount = CommonLib._getBalanceOf(outputToken) - balanceBefore;
    }

    /// @notice Swaps `action.inputToken` into a `action.outputToken`
    ///         with an extra slippage check.
    /// @param cr The address of the Protocol Central Registry to pull
    ///           addresses from.
    /// @param action Instructions for a swap action containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @return outAmount The output amount received from swapping.
    function _swapSafe(
        ICentralRegistry cr,
        Swap memory action
    ) internal returns (uint256 outAmount) {
        outAmount = _swapUnsafe(cr, action);

        IOracleManager om = IOracleManager(cr.oracleManager());
        uint256 valueIn = _getValue(om, action.inputToken, action.inputAmount);
        uint256 valueOut = _getValue(om, action.outputToken, outAmount);

        // Check if swap received positive slippage.
        if (valueOut > valueIn) {
            return outAmount;
        }

        // Calculate % slippage from executed swap.
        uint256 slippage = FixedPointMathLib.mulDiv(
            valueIn - valueOut,
            WAD,
            valueIn
        );

        if (slippage > action.slippage || slippage > cr.slippageLimit()) {
            revert SwapperLib__Slippage(slippage);
        }
    }

    /// @notice Get the value of a token amount.
    /// @notice Approves `token` spending allowance, if needed.
    /// @param om The Oracle Manager address to call for pricing `token`.
    /// @param token The token address to get the value of.
    /// @param amount The amount of `token` to get the value of.
    function _getValue(
        IOracleManager om,
        address token,
        uint256 amount
    ) internal view returns (uint256 result) {
        (uint256 price, uint256 errorCode) = om.getPrice(token, true, true);
        if (errorCode != NO_ERROR) {
            revert SwapperLib__TokenPrice(token);
        }

        // Return price in WAD form.
        result = FixedPointMathLib.mulDiv(
            price,
            amount,
            10 ** (CommonLib._isNative(token) ? 18 : IERC20(token).decimals())
        );
    }

    /// @notice Approves `token` spending allowance, if needed.
    /// @param token The token address to approve.
    /// @param spender The spender address.
    /// @param amount The approval amount.
    function _approveIfNeeded(
        address token,
        address spender,
        uint256 amount
    ) internal {
        if (!CommonLib._isNative(token)) {
            SafeTransferLib.safeApprove(token, spender, amount);
        }
    }

    /// @notice Removes `token` spending allowance, if needed.
    /// @param token The token address to remove approval.
    /// @param spender The spender address.
    function _removeApprovalIfNeeded(address token, address spender) internal {
        if (!CommonLib._isNative(token)) {
            if (IERC20(token).allowance(address(this), spender) > 0) {
                SafeTransferLib.safeApprove(token, spender, 0);
            }
        }
    }
}
