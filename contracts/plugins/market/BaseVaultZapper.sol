// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseZapper, ICentralRegistry, SwapperLib, ICToken } from "contracts/plugins/BaseZapper.sol";

import { IVault } from "contracts/interfaces/IVault.sol";

abstract contract BaseVaultZapper is BaseZapper {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) BaseZapper(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Withdraws from a Curvance position, and swaps it into
    ///         desired token (swapAction.outputToken).
    /// @dev Requires plugin approval for redemption.
    /// @param redeemAction Instructions for a redemption action containing:
    ///                     cToken The address of the cToken corresponding to
    ///                            the redemption action.
    ///                     shares The amount of shares to redeemed.
    ///                     forceRedeemCollateral Whether the collateral
    ///                                           should be always reduced
    ///                                           from caller's collateralized
    ///                                           shares.
    /// @param swapAction Instructions for a swap action containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @param receiver Address that should receive `swapAction.outputToken`.
    /// @return outAmount The amount of `swapAction.outputToken` that was
    ///                   received by `receiver`.
    function redeemAndSwap(
        RedeemAction calldata redeemAction,
        SwapperLib.Swap memory swapAction,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        
        IVault vault = IVault(ICToken(redeemAction.cToken).asset());
        address asset = address(vault.asset());

        if(asset != swapAction.inputToken) {
            revert BaseZapper__UnderlyingTokenIsNotInputToken();
        }

        // Exit Curvance position.
        _exitCurvanceSafe(
            redeemAction.cToken,
            address(vault),
            redeemAction.shares,
            swapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            receiver
        );

        // Redeem vault shares to get underlying asset
        swapAction.inputAmount = vault.redeem(
            swapAction.inputAmount,
            address(this),
            address(this)
        );
        // Update the input token to the actual underlying asset
        swapAction.inputToken = asset;

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;
        } else {
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        _transferToRecipient(swapAction.outputToken, receiver, outAmount);
    }

    /// @notice Withdraws a Curvance position, swaps it into
    ///         desired token (swapAction.outputToken) and then deposits
    ///         it into a new position.
    /// @dev Requires plugin approval for redemption.
    /// @param cToken The Curvance token (cToken) address.
    /// @param redeemAction Instructions for a redemption action containing:
    ///                     cToken The address of the cToken corresponding to
    ///                            the redemption action.
    ///                     shares The amount of shares to redeemed.
    ///                     forceRedeemCollateral Whether the collateral
    ///                                           should be always reduced
    ///                                           from caller's collateralized
    ///                                           shares.
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
    /// @param collateralizeFor Whether the deposit should be collateralized,
    ///                         requires plugin approval.
    /// @param receiver Address that should receive `cToken` shares.
    /// @return outAmount The `cToken` output shares received by `receiver`.
    function redeemSwapAndDeposit(
        address cToken,
        RedeemAction calldata redeemAction,
        SwapperLib.Swap memory swapAction,
        uint256 expectedShares,
        bool collateralizeFor,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvanceSafe(
            redeemAction.cToken,
            swapAction.inputToken,
            redeemAction.shares,
            swapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            receiver
        );

        swapAction.inputAmount = IVault(swapAction.inputToken).redeem(
            swapAction.inputAmount,
            address(this),
            address(this)
        );
        swapAction.inputToken = ICToken(swapAction.inputToken).asset();

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into `swapAction.outputToken` which should be
            // new cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Enter Curvance position.
        outAmount = _enterCurvance(
            cToken,
            swapAction.outputToken,
            outAmount,
            expectedShares,
            collateralizeFor,
            receiver
        );
    }
}
