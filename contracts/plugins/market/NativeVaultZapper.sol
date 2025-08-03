// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseVaultZapper, ICentralRegistry, SwapperLib, ICToken, IVault } from "contracts/plugins/market/BaseVaultZapper.sol";

import { CommonLib } from "contracts/libraries/CommonLib.sol";

import { IWETH } from "contracts/interfaces/IWETH.sol";

contract NativeVaultZapper is BaseVaultZapper {
    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr, address wNative) BaseVaultZapper(cr, wNative) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps, then deposits `swapAction.outputToken`, a cToken
    ///         asset, and enters into Curvance position, for `receiver`.
    /// @dev Requires plugin approval for collateralization.
    /// @param cToken The Curvance token (cToken) address to deposit into.
    /// @param swapAction Instructions for executing a swap into collateral
    ///                   asset.
    ///                   Containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of
    ///                       `swapAction.outputToken` into `cToken` position.
    /// @param collateralizeFor Whether the zapped deposit should be
    ///                         collateralized afterwards.
    /// @param receiver Address that should receive `cToken` shares.
    /// @return outAmount The `cToken` output shares received by `receiver`.
    function swapAndDeposit(
        address cToken,
        SwapperLib.Swap memory swapAction,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) external payable nonReentrant returns (uint256 outAmount) {
        _prepareSwap(swapAction.inputToken, swapAction.inputAmount, false);

        if(!CommonLib._isNative(swapAction.outputToken)) {
            revert BaseZapper__UnderlyingTokenIsNotInputToken();
        }

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;        
        } else if (swapAction.inputToken == wrappedNative) {
            // Make sure they are not attaching native tokens when
            // we want wrapped native.
            if (msg.value > 0) {
                revert BaseZapper__ExecutionError();
            }

            SwapperLib._approveIfNeeded(
                wrappedNative,
                wrappedNative,
                swapAction.inputAmount
            );
            IWETH(wrappedNative).withdraw(swapAction.inputAmount);
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        IVault vault = IVault(ICToken(cToken).asset());

        // Deposit into vault.
        outAmount = vault.deposit{value: outAmount}(outAmount, address(this));
        
        // Enter Curvance position.
        outAmount = _enterCurvance(
            cToken,
            address(vault),
            outAmount,
            expectedShares,
            collateralizeFor,
            receiver
        );
    }
}
