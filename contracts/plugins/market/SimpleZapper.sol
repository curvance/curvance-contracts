// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ZapperBase, CommonLib, IMToken, IERC20, SafeTransferLib, ICentralRegistry } from "contracts/plugins/ZapperBase.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IWETH } from "contracts/interfaces/IWETH.sol";

contract SimpleZapper is ZapperBase {
    /// ERRORS ///

    error SimpleZapper__Unauthorized();
    error SimpleZapper__ExecutionError();
    error SimpleZapper__InsufficientToRepay();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) ZapperBase(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `swapData.outputToken`, a pToken
    ///         underlying, and enters into Curvance position,
    ///         for `recipient`.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param depositAsWrappedNative Used only if `swapData.inputToken` is
    ///                               a chain's native token, dictates whether
    ///                               native should be deposited as native or
    ///                               wrapped native.
    /// @param swapData Swap instruction data to execute the swap.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return The output amount received from Zapping.
    function swapAndDeposit(
        address pToken,
        bool depositAsWrappedNative,
        SwapperLib.Swap memory swapData,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256) {
        if (CommonLib.isETH(swapData.inputToken)) {
            // Validate message has gas token attached.
            if (swapData.inputAmount != msg.value) {
                revert SimpleZapper__ExecutionError();
            }

            if (depositAsWrappedNative) {
                IWETH(wrappedNative).deposit{ value: swapData.inputAmount }();
            }
        } else {
            SafeTransferLib.safeTransferFrom(
                swapData.inputToken,
                msg.sender,
                address(this),
                swapData.inputAmount
            );
        }

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
            // Execute swap into pToken underlying.
            amount = SwapperLib.swapUnsafe(centralRegistry, swapData);
        }

        // Enter Curvance pToken position.
        return
            _enterCurvance(
                pToken,
                swapData.outputToken,
                amount,
                collateralize,
                recipient
            );
    }

    /// @notice Swaps then repays eToken debt inside Curvance for `recipient`.
    /// @dev Sends any excess eToken underlying to `recipient`.
    /// @param depositAsWrappedNative Used only if `swapData.inputToken` is
    ///                               a chain's native token, dictates whether
    ///                               native should be deposited as native or
    ///                               wrapped native.
    /// @param swapData Swap instruction data to execute the repayment.
    /// @param eToken The Curvance eToken address.
    /// @param repayAmount The amount of eToken underlying to be repaid.
    /// @param recipient Address that should have its outstanding debt repaid.
    /// @return The excess amount of eToken underlying that was returned
    ///         to `recipient`.
    function swapAndRepay(
        bool depositAsWrappedNative,
        SwapperLib.Swap memory swapData,
        address eToken,
        uint256 repayAmount,
        address recipient
    ) external payable nonReentrant returns (uint256) {
        if (CommonLib.isETH(swapData.inputToken)) {
            // Validate message has gas token attached.
            if (swapData.inputAmount != msg.value) {
                revert SimpleZapper__ExecutionError();
            }

            if (depositAsWrappedNative) {
                IWETH(wrappedNative).deposit{ value: swapData.inputAmount }();
            }
        } else {
            SafeTransferLib.safeTransferFrom(
                swapData.inputToken,
                msg.sender,
                address(this),
                swapData.inputAmount
            );
        }

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

        return _repayDebt(eToken, eTokenUnderlying, amount, repayAmount, recipient);
    }

    /// @notice Withdraws a Curvance position, and swaps it into
    ///         desired token (swapData.outputToken).
    /// @dev Requires plugin approval for redemption.
    /// @param redemptionData Struct containing information on redemption action
    ///                       to execute. Containing values:
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
            IMToken(redemptionData.mToken),
            redemptionData.shares,
            redemptionData.forceRedeemCollateral,
            swapData.inputToken,
            swapData.inputAmount,
            recipient
        );

        // Execute swap into `swapData.outputToken`.
        uint256 outAmount = SwapperLib.swapUnsafe(centralRegistry, swapData);

        _transferToRecipient(swapData.outputToken, recipient, outAmount);

        return outAmount;
    }
}
