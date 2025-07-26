// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ZapperBase, ICentralRegistry } from "contracts/plugins/ZapperBase.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

contract VaultZapper is ZapperBase {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) ZapperBase(centralRegistry_, wrappedNative_) {}

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
    ) external payable nonReentrant returns (uint256 outAmount) {
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

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into cToken underlying.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Validate token address parameters are valid, then deposit into vault.
        outAmount = IVault(_checkAddresses(cToken, swapAction.outputToken)).deposit(
            outAmount,
            address(this)
        );

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

    /// @notice Withdraws from a Curvance position, and swaps it into
    ///         desired token (swapAction.outputToken).
    /// @dev Requires plugin approval for redemption.
    /// @param redeemAction Struct containing information on redemption
    ///                     action to execute. Containing values:
    ///                     1. The address of the cToken corresponding to
    ///                        position to be exited.
    ///                     2. The amount of shares to redeemed.
    ///                     3. Whether the collateral should be directly
    ///                        reduced from caller's posted collateral.
    /// @param swapAction Instructions for executing a swap.
    /// @param receiver Address that should receive `swapAction.outputToken`.
    /// @return outAmount The amount of `swapAction.outputToken` that was
    ///                   received by `receiver`.
    function redeemAndSwap(
        RedeemAction calldata redeemAction,
        SwapperLib.Swap memory swapAction,
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
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        _transferToRecipient(swapAction.outputToken, receiver, outAmount);
    }

    /// @notice Withdraws a Curvance position, swaps it into
    ///         desired token (swapAction.outputToken) and then deposits
    ///         it into a new position.
    /// @dev Requires plugin approval for redemption.
    /// @param cToken The Curvance token (cToken) address.
    /// @param redeemAction Struct containing information on redemption
    ///                     action to execute. Containing values:
    ///                     1. The address of the cToken corresponding to
    ///                        position to be exited.
    ///                     2. The amount of shares to redeemed.
    ///                     3. Whether the collateral should be directly
    ///                        reduced from caller's posted collateral.
    /// @param swapAction Instructions for executing a swap into collateral
    ///                   asset.
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
            // new cToken underlying.
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
