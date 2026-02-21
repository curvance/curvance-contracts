// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseZapper, ICentralRegistry, SwapperLib, CommonLib, ICToken } from "contracts/plugins/BaseZapper.sol";

/// @title Curvance Simple Zapper.
/// @notice Simple Asset-specific contract for executing zap related
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
///      The "Simple" contract is the zapper for working with generic
///      non-native erc20 tokens such as USDC or WETH.
///
contract SimpleZapper is BaseZapper {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param wNative The address of wrapped native token.
    constructor(ICentralRegistry cr, address wNative) BaseZapper(cr, wNative) {}

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
    ) external virtual payable nonReentrant returns (uint256 outAmount) {
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

        if (CommonLib._isMatchingToken(swapAction.inputToken, swapAction.outputToken)) {
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into cToken asset.
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
    /// @param repayAssets The minimum amount, in assets, to be creditable
    ///                    to `receiver` through repayment and/or direct
    ///                    transfer.
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
        // Zero amount repayment is not supported in Zappers as we already
        // repay as much debt as possible.
        if (repayAssets == 0) {
            revert BaseZapper__InvalidRepaymentAmount();
        }

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

        if (CommonLib._isMatchingToken(swapAction.inputToken, swapAction.outputToken)) {
            outAmount = swapAction.inputAmount;
        } else {
            // Execute swap into cToken asset.
            outAmount = SwapperLib._swapUnsafe(centralRegistry, swapAction);
        }

        // Revert if less than `repayAssets` was received, then repay as much
        // of `receiver`'s debt as possible.
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
        _exitCurvance(
            redeemAction.cToken,
            swapAction.inputToken,
            redeemAction.shares,
            swapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            receiver
        );

        if (CommonLib._isMatchingToken(swapAction.inputToken, swapAction.outputToken)) {
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
        _exitCurvance(
            redeemAction.cToken,
            swapAction.inputToken,
            redeemAction.shares,
            swapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            receiver
        );

        if (CommonLib._isMatchingToken(swapAction.inputToken, swapAction.outputToken)) {
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
