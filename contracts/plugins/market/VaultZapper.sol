// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ICentralRegistry } from "contracts/plugins/ZapperBase.sol";
import { BaseVaultZapper } from "./BaseVaultZapper.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract VaultZapper is BaseVaultZapper {
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
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
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
        bool depositAsWrappedNative,
        SwapperLib.Swap memory swapAction,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) override external payable nonReentrant returns (uint256 outAmount) {

        IVault vault; 
        vault = IVault(ICToken(cToken).asset());
        address asset = address(vault.asset());

        _prepareSwap(
            swapAction.inputToken,
            swapAction.inputAmount,
            depositAsWrappedNative
        );

        // If we are trying to deposit wrapped native, we may be able to skip
        // a swapper call by changing the input token and checking versus
        // output token.
        if (CommonLib._isNative(swapAction.inputToken) && depositAsWrappedNative) {
            // Switch inputToken to wrapped native token address.
            swapAction.inputToken = address(wrappedNative);
        }

        if(asset != swapAction.outputToken) {
            revert ZapperBase__UnderlyingTokenIsNotInputToken();
        }

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        SwapperLib._approveIfNeeded(swapAction.outputToken, address(vault), outAmount);

        // Validate token address parameters are valid, then deposit into vault.
        outAmount = vault.deposit(
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
