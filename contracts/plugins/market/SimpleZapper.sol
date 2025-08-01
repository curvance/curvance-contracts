// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseZapper, ICentralRegistry } from "contracts/plugins/BaseZapper.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

contract SimpleZapper is BaseZapper {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) BaseZapper(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `swapAction.outputToken`, a cToken asset,
    ///         and enters into Curvance position, for `receiver`.
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
    /// @param collateralizeFor Whether the deposit should be collateralized,
    ///                         requires plugin approval.
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
            // Execute swap into cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Enter Curvance position.
        outAmount = _enterCurvanceSafe(
            cToken,
            swapAction.outputToken,
            outAmount,
            expectedShares,
            collateralizeFor,
            receiver
        );
    }

    /// @notice Swaps then repays outstanding debt for `receiver`.
    /// @dev Sends any excess debt token to `receiver`.
    /// @param borrowableCToken The Curvance token address to repay debt to.
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    /// @param swapAction Instructions for executing a swap into debt asset.
    ///                   Containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @param repayAssets The amount of debt to be repaid, in assets.
    /// @param receiver Address that should have its outstanding debt repaid.
    /// @return outAmount The excess amount of debt token that was returned to
    ///                   `receiver`.
    function swapAndRepay(
        address borrowableCToken,
        bool depositAsWrappedNative,
        SwapperLib.Swap memory swapAction,
        uint256 repayAssets,
        address receiver
    ) external payable nonReentrant returns (uint256 outAmount) {
        _prepareSwap(
            swapAction.inputToken,
            swapAction.inputAmount,
            depositAsWrappedNative
        );

        // If we are trying to repay wrapped native, we may be able to skip
        // a swapper call by changing the input token and checking versus
        // output token.
        if (CommonLib._isNative(swapAction.inputToken) && depositAsWrappedNative) {
            // Switch inputToken to wrapped native token address.
            swapAction.inputToken = address(wrappedNative);
        }

        // Validate token address parameters are valid.
        _checkAddresses(borrowableCToken, swapAction.outputToken);

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Repay `repayAssets` outstanding debt.
        outAmount = _repayDebt(
            borrowableCToken,
            swapAction.outputToken,
            outAmount,
            repayAssets,
            receiver
        );
    }

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
    /// @param swapAction Instructions for executing a swap into debt asset.
    ///                   Containing:
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
        // Exit Curvance position.
        _exitCurvanceSafe(
            redeemAction.cToken,
            swapAction.inputToken,
            redeemAction.shares,
            swapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            receiver
        );

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

        if (swapAction.inputToken == swapAction.outputToken) {
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into `swapAction.outputToken` which should be
            // new cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Enter Curvance position.
        outAmount = _enterCurvanceSafe(
            cToken,
            swapAction.outputToken,
            outAmount,
            expectedShares,
            collateralizeFor,
            receiver
        );
    }
}
