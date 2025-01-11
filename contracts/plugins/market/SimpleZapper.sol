// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ZapperBase, SwapperLib, CommonLib, IMToken, IPToken, ICentralRegistry } from "contracts/plugins/ZapperBase.sol";

contract SimpleZapper is ZapperBase {
    /// ERRORS ///

    error SimpleZapper__Unauthorized();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) ZapperBase(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `swapData.outputToken`, a mToken
    ///         underlying, and enters into Curvance position,
    ///         for `recipient`.
    /// @dev Requires plugin approval for collateralization.
    /// @param mToken The Curvance position token (mToken) address.
    /// @param depositAsWrappedNative Used only if `swapData.inputToken` is
    ///                               a chain's native token, dictates whether
    ///                               native should be deposited as native or
    ///                               wrapped native.
    /// @param swapData Swap instruction data to execute the swap.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapData.outputToken`
    ///                       into `mToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return The output amount received from Zapping.
    function swapAndDeposit(
        address mToken,
        bool isPToken,
        bool depositAsWrappedNative,
        SwapperLib.Swap memory swapData,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256) {
        _prepareSwap(
            swapData.inputToken,
            swapData.inputAmount,
            depositAsWrappedNative
        );

        // If we are trying to deposit wrapped native, we may be able to skip
        // a swapper call by changing the input token and checking versus
        // output token.
        if (CommonLib.isETH(swapData.inputToken) && depositAsWrappedNative) {
            // Switch inputToken to wrapped native token address.
            swapData.inputToken = address(wrappedNative);
        }

        uint256 amount;
        if (swapData.inputToken == swapData.outputToken) {
            amount = swapData.inputAmount;
        } else {
            // Execute swap into mToken underlying.
            amount = SwapperLib.swapUnsafe(centralRegistry, swapData);
        }

        // Enter Curvance mToken position.
        return
            _enterCurvance(
                mToken,
                swapData.outputToken,
                isPToken,
                amount,
                expectedShares,
                collateralize,
                recipient
            );
    }

    /// @notice Swaps then repays eToken debt inside Curvance for `recipient`.
    /// @dev Sends any excess eToken underlying to `recipient`.
    /// @param eToken The Curvance eToken address.
    /// @param depositAsWrappedNative Used only if `swapData.inputToken` is
    ///                               a chain's native token, dictates whether
    ///                               native should be deposited as native or
    ///                               wrapped native.
    /// @param swapData Swap instruction data to execute the repayment.
    /// @param repayAmount The amount of eToken underlying to be repaid.
    /// @param recipient Address that should have its outstanding debt repaid.
    /// @return The excess amount of eToken underlying that was returned
    ///         to `recipient`.
    function swapAndRepay(
        address eToken,
        bool depositAsWrappedNative,
        SwapperLib.Swap memory swapData,
        uint256 repayAmount,
        address recipient
    ) external payable nonReentrant returns (uint256) {
        _prepareSwap(
            swapData.inputToken,
            swapData.inputAmount,
            depositAsWrappedNative
        );

        // If we are trying to repay wrapped native, we may be able to skip
        // a swapper call by changing the input token and checking versus
        // output token.
        if (CommonLib.isETH(swapData.inputToken) && depositAsWrappedNative) {
            // Switch inputToken to wrapped native token address.
            swapData.inputToken = address(wrappedNative);
        }

        uint256 amount;
        // Cache underlying to minimize external calls.
        address eTokenUnderlying = IMToken(eToken).underlying();

        // Make sure if we are swapping that we are swapping into the proper
        // underlying token.
        if (swapData.outputToken != eTokenUnderlying) {
            revert SimpleZapper__Unauthorized();
        }

        if (swapData.inputToken == swapData.outputToken) {
            amount = swapData.inputAmount;
        } else {
            // Execute swap into eToken underlying.
            amount = SwapperLib.swapUnsafe(centralRegistry, swapData);
        }

        return
            _repayDebt(
                eToken,
                eTokenUnderlying,
                amount,
                repayAmount,
                recipient
            );
    }

    /// @notice Withdraws a Curvance position, and swaps it into
    ///         desired token (swapData.outputToken).
    /// @dev Requires plugin approval for redemption.
    /// @param redemptionData Struct containing information on redemption
    ///                       action to execute. Containing values:
    ///                       1. The address of the mToken corresponding to
    ///                          position to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param swapData Swap instruction data to execute the repayment.
    /// @param recipient Address that should have its outstanding debt repaid.
    /// @return The excess amount of eToken underlying that was returned
    ///         to `recipient`.
    function redeemAndSwap(
        RedemptionData calldata redemptionData,
        SwapperLib.Swap memory swapData,
        address recipient
    ) external nonReentrant returns (uint256) {
        // Exit Curvance position.
        _exitCurvance(
            IPToken(redemptionData.mToken),
            swapData.inputToken,
            redemptionData.shares,
            swapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            recipient
        );

        // Execute swap into `swapData.outputToken`.
        uint256 outAmount = SwapperLib.swapUnsafe(centralRegistry, swapData);

        _transferToRecipient(swapData.outputToken, recipient, outAmount);

        return outAmount;
    }
}
