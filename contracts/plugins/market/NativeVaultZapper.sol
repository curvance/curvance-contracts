// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ICentralRegistry } from "contracts/plugins/BaseZapper.sol";
import { BaseVaultZapper } from "./BaseVaultZapper.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";

contract NativeVaultZapper is BaseVaultZapper {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) BaseVaultZapper(centralRegistry_, wrappedNative_) {}

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

        IVault vault = IVault(ICToken(cToken).asset());

        _prepareSwap(
            swapAction.inputToken,
            swapAction.inputAmount,
            false
        );

        if(!CommonLib._isNative(swapAction.outputToken)) {
            revert BaseZapper__UnderlyingTokenIsNotInputToken();
        }

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;        
        }
        else if (swapAction.inputToken == wrappedNative) {
            if (msg.value > 0) revert("no");
            SwapperLib._approveIfNeeded(wrappedNative, wrappedNative, swapAction.inputAmount);
            IWETH(wrappedNative).withdraw(swapAction.inputAmount);
            outAmount = swapAction.inputAmount;
        }
        else {
            // Execute swap into cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Validate token address parameters are valid, then deposit into vault.
        outAmount = vault.deposit{value: outAmount}(
            outAmount,
            address(this)
        );
        
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
