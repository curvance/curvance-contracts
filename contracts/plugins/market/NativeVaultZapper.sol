// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SimpleZapper, ICentralRegistry, SwapperLib, ICToken } from "contracts/plugins/market/SimpleZapper.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

import { IWETH } from "contracts/interfaces/IWETH.sol";


/// @title Curvance Native Vault Zapper.
/// @notice Native Vault-specific contract for executing zap related
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
///      The "Native Vault" contract is the zapper for working with
///      native-token based erc4626 tokens such as shMON or aprMON. No type
///      specific "redeemAnd" is written as execution is intended to be the
///      as the "simple" zappers where redemptions are done directly on the
///      corresponding cToken.
///
contract NativeVaultZapper is SimpleZapper {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param wNative The address of wrapped native token.
    constructor(ICentralRegistry cr, address wNative) SimpleZapper(cr, wNative) {}

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
        bool /* depositAsWrappedNative */,
        SwapperLib.Swap memory swapAction,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) external override payable nonReentrant returns (uint256 outAmount) {
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
