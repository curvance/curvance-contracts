// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IExternalCalldataChecker } from "contracts/interfaces/IExternalCalldataChecker.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { NO_ERROR, WAD } from "contracts/libraries/Constants.sol";

library SwapperLib {
    /// TYPES ///
    /// @notice Used to execute a swap, which is selling one token for another.
    /// @param inputToken Address of input token to swap from.
    /// @param inputAmount The amount of `inputToken` to swap.
    /// @param outputToken Address of token to swap into.
    /// @param target Address of the swapper, usually an aggregator.
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

    error SwapperLib__SwapError();
    error SwapperLib__UnknownCalldata();
    error SwapperLib__TokenPrice(address inputToken);
    error SwapperLib__Slippage(uint256 slippage);

    /// FUNCTIONS ///

    /// @notice Swaps `swapData.inputToken` into a `swapData.outputToken`. (unsafe)
    /// @param swapData The swap instruction data to execute.
    /// @return The output amount received from swapping.
    function swapUnsafe(
        ICentralRegistry centralRegistry,
        Swap memory swapData
    ) internal returns (uint256) {
        address callDataChecker = centralRegistry.externalCalldataChecker(
            swapData.target
        );

        // Validate we know how to verify this calldata.
        if (callDataChecker == address(0)) {
            revert SwapperLib__UnknownCalldata();
        }

        // Verify calldata integrity.
        IExternalCalldataChecker(callDataChecker).checkCalldata(
            swapData,
            address(this)
        );

        // Approve `swapData.inputToken` to target contract, if necessary.
        _approveTokenIfNeeded(
            swapData.inputToken,
            swapData.target,
            swapData.inputAmount
        );

        // Cache output token from struct for easier querying.
        address outputToken = swapData.outputToken;
        uint256 balance = CommonLib.getTokenBalance(outputToken);

        uint256 value = CommonLib.isETH(swapData.inputToken)
            ? swapData.inputAmount
            : 0;

        // Execute the swap.
        (bool success, bytes memory auxData) = swapData.target.call{
            value: value
        }(swapData.call);

        propagateError(success, auxData);

        // Remove any excess approval.
        _removeApprovalIfNeeded(swapData.inputToken, swapData.target);

        return CommonLib.getTokenBalance(outputToken) - balance;
    }

    /// @notice Swaps `swapData.inputToken` into a `swapData.outputToken`. (safe: check slippage)
    /// @param swapData The swap instruction data to execute.
    /// @return outAmount The output amount received from swapping.
    function swapSafe(
        ICentralRegistry centralRegistry,
        Swap memory swapData
    ) internal returns (uint256 outAmount) {
        {
            address callDataChecker = centralRegistry.externalCalldataChecker(
                swapData.target
            );

            // Validate we know how to verify this calldata.
            if (callDataChecker == address(0)) {
                revert SwapperLib__UnknownCalldata();
            }

            // Verify calldata integrity.
            IExternalCalldataChecker(callDataChecker).checkCalldata(
                swapData,
                address(this)
            );

            // Approve `swapData.inputToken` to target contract, if necessary.
            _approveTokenIfNeeded(
                swapData.inputToken,
                swapData.target,
                swapData.inputAmount
            );

            // Cache output token from struct for easier querying.
            uint256 balance = CommonLib.getTokenBalance(swapData.outputToken);

            uint256 value = CommonLib.isETH(swapData.inputToken)
                ? swapData.inputAmount
                : 0;

            // Execute the swap.
            (bool success, bytes memory auxData) = swapData.target.call{
                value: value
            }(swapData.call);

            propagateError(success, auxData);

            // Remove any excess approval.
            _removeApprovalIfNeeded(swapData.inputToken, swapData.target);

            outAmount =
                CommonLib.getTokenBalance(swapData.outputToken) -
                balance;
        }

        {
            IOracleManager oracleManager = IOracleManager(
                centralRegistry.oracleManager()
            );
            (uint256 inputTokenPrice, uint256 errorCode) = oracleManager
                .getPrice(swapData.inputToken, true, true);
            if (errorCode != NO_ERROR) {
                revert SwapperLib__TokenPrice(swapData.inputToken);
            }

            uint256 outputTokenPrice;
            (outputTokenPrice, errorCode) = oracleManager.getPrice(
                swapData.outputToken,
                true,
                true
            );
            if (errorCode != NO_ERROR) {
                revert SwapperLib__TokenPrice(swapData.outputToken);
            }

            uint256 inputValue = (inputTokenPrice * swapData.inputAmount) /
                (10 **
                    (
                        CommonLib.isETH(swapData.inputToken)
                            ? 18
                            : IERC20(swapData.inputToken).decimals()
                    ));
            uint256 outputValue = (outputTokenPrice * outAmount) /
                (10 **
                    (
                        CommonLib.isETH(swapData.outputToken)
                            ? 18
                            : IERC20(swapData.outputToken).decimals()
                    ));

            // Check if swap received positive slippage.
            if (outputValue > inputValue) {
                return outAmount;
            }

            // Calculate % slippage from executed swap.
            uint256 slippage = ((inputValue - outputValue) * WAD) / inputValue;
            if (
                slippage > swapData.slippage ||
                slippage > centralRegistry.slippageLimit()
            ) {
                revert SwapperLib__Slippage(slippage);
            }
        }
    }

    /// @notice Approves `token` spending allowance, if needed.
    /// @param token The token address to approve.
    /// @param spender The spender address.
    /// @param amount The approval amount.
    function _approveTokenIfNeeded(
        address token,
        address spender,
        uint256 amount
    ) internal {
        if (!CommonLib.isETH(token)) {
            SafeTransferLib.safeApprove(token, spender, amount);
        }
    }

    /// @notice Removes `token` spending allowance, if needed.
    /// @param token The token address to remove approval.
    /// @param spender The spender address.
    function _removeApprovalIfNeeded(address token, address spender) internal {
        if (!CommonLib.isETH(token)) {
            if (IERC20(token).allowance(address(this), spender) > 0) {
                SafeTransferLib.safeApprove(token, spender, 0);
            }
        }
    }

    /// @dev Propagates an error message.
    /// @param success If transaction was successful.
    /// @param data The transaction result data.
    function propagateError(bool success, bytes memory data) internal pure {
        if (!success) {
            if (data.length == 0) {
                revert SwapperLib__SwapError();
            }
            assembly {
                revert(add(32, data), mload(data))
            }
        }
    }
}
