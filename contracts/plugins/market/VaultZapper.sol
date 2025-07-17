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

    /// @notice Swaps then deposits `swapData.outputToken`, a cToken
    ///         underlying, and enters into Curvance position,
    ///         for `receiver`.
    /// @dev Requires plugin approval for collateralization.
    /// @param cToken The Curvance token (cToken) address to deposit into.
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    /// @param swapData Swap instruction data to execute the swap.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of
    ///                       `swapData.outputToken` into `cToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param receiver Address that should receive `cToken` shares.
    /// @return outAmount The `cToken` output shares received by `receiver`.
    function swapAndDeposit(
        address cToken,
        bool depositAsWrappedNative,
        SwapperLib.Swap memory swapData,
        uint256 expectedShares,
        bool collateralize,
        address receiver
    ) external payable nonReentrant returns (uint256 outAmount) {
        _prepareSwap(
            swapData.inputToken,
            swapData.inputAmount,
            depositAsWrappedNative
        );

        // If we are trying to deposit wrapped native, we may be able to skip
        // a swapper call by changing the input token and checking versus
        // output token.
        if (CommonLib._isNative(swapData.inputToken) && depositAsWrappedNative) {
            // Switch inputToken to wrapped native token address.
            swapData.inputToken = address(wrappedNative);
        }

        if (swapData.inputToken == swapData.outputToken) {
            outAmount = swapData.inputAmount;
        } else {
            // Execute swap into cToken underlying.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapData);
        }

        // Validate token address parameters are valid, then deposit into vault.
        outAmount = IVault(_checkAddresses(cToken, swapData.outputToken)).deposit(
            outAmount,
            address(this)
        );

        // Enter Curvance position.
        outAmount = _enterCurvance(
            cToken,
            swapData.outputToken,
            outAmount,
            expectedShares,
            collateralize,
            receiver
        );
    }

    /// @notice Withdraws from a Curvance position, and swaps it into
    ///         desired token (swapData.outputToken).
    /// @dev Requires plugin approval for redemption.
    /// @param redemptionData Struct containing information on redemption
    ///                       action to execute. Containing values:
    ///                       1. The address of the cToken corresponding to
    ///                          position to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param swapData Swap instruction data to execute the repayment.
    /// @param receiver Address that should receive `swapData.outputToken`.
    /// @return outAmount The amount of `swapData.outputToken` that was
    ///                   received by `receiver`.
    function redeemAndSwap(
        RedemptionData calldata redemptionData,
        SwapperLib.Swap memory swapData,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvanceSafe(
            redemptionData.cToken,
            swapData.inputToken,
            redemptionData.shares,
            swapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            receiver
        );

        swapData.inputAmount = IVault(swapData.inputToken).redeem(
            swapData.inputAmount,
            address(this),
            address(this)
        );
        swapData.inputToken = ICToken(swapData.inputToken).asset();

        if (swapData.inputToken == swapData.outputToken) {
            outAmount = swapData.inputAmount;
        } else {
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapData);
        }

        _transferToRecipient(swapData.outputToken, receiver, outAmount);
    }

    /// @notice Withdraws a Curvance position, swaps it into
    ///         desired token (swapData.outputToken) and then deposits
    ///         it into a new position.
    /// @dev Requires plugin approval for redemption.
    /// @param cToken The Curvance position token (cToken) address.
    /// @param redemptionData Struct containing information on redemption
    ///                       action to execute. Containing values:
    ///                       1. The address of the cToken corresponding to
    ///                          position to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param swapData Swap instruction data to execute the repayment.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of
    ///                       `swapData.outputToken` into `cToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param receiver Address that should receive `cToken` shares.
    /// @return outAmount The `cToken` output shares received by `receiver`.
    function redeemSwapAndDeposit(
        address cToken,
        RedemptionData calldata redemptionData,
        SwapperLib.Swap memory swapData,
        uint256 expectedShares,
        bool collateralize,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvanceSafe(
            redemptionData.cToken,
            swapData.inputToken,
            redemptionData.shares,
            swapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            receiver
        );

        swapData.inputAmount = IVault(swapData.inputToken).redeem(
            swapData.inputAmount,
            address(this),
            address(this)
        );
        swapData.inputToken = ICToken(swapData.inputToken).asset();

        if (swapData.inputToken == swapData.outputToken) {
            outAmount = swapData.inputAmount;
        } else {
            // Execute swap into `swapData.outputToken` which should be
            // new cToken underlying.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapData);
        }

        // Enter Curvance position.
        outAmount = _enterCurvance(
            cToken,
            swapData.outputToken,
            outAmount,
            expectedShares,
            collateralize,
            receiver
        );
    }
}
