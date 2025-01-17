// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ZapperBase, SwapperLib, CommonLib, IMToken, IPToken, SafeTransferLib, ICentralRegistry } from "contracts/plugins/ZapperBase.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";

contract PendleZapper is ZapperBase {
    /// TYPES ///

    /// @param inputToken Address of input token to Zap from.
    /// @param inputAmount The amount of `inputToken` to Zap.
    /// @param outputToken Address of token Zapped into.
    /// @param minimumOut The minimum amount of `outputToken` acceptable
    ///                   from the Zap.
    /// @param depositAsWrappedNative Used only if `inputToken` is a chain's
    ///                               native token, dictates whether native
    ///                               should be deposited as native or wrapped
    ///                               native.
    struct ZapperData {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 minimumOut;
        bool depositAsWrappedNative;
    }

    /// ERRORS ///

    error PendleZapper__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) ZapperBase(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapData.inputToken` into Pendle
    ///         market, and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapData.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterPendle(
        address pToken,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address router,
        bool isPt,
        PendleLib.PendleData calldata data,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapData.inputToken,
            zapData.inputAmount,
            swapData,
            zapData.depositAsWrappedNative
        );

        // Enter Pendle position.
        outAmount = PendleLib.enterPendle(
            router,
            isPt,
            data,
            zapData.outputToken,
            zapData.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapData.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a Pendle market, and zaps it into desired
    ///         token (zapData.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitPendle(
        address router,
        bool isPt,
        address token,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Pendle market to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapData.inputToken,
            msg.sender,
            address(this),
            zapData.inputAmount
        );

        // Exit Pendle lp position.
        outAmount = _exitPendle(
            router,
            isPt,
            token,
            data,
            zapData,
            swapData,
            recipient
        );
    }

    /// @notice Withdraws a Curvance Pendle market position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param redemptionData Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the pToken corresponding to Curve lp
    ///                          token to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitPendle(
        RedemptionData calldata redemptionData,
        address router,
        bool isPt,
        address token,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redemptionData.mToken,
            zapData.inputToken,
            redemptionData.shares,
            zapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            recipient
        );

        // Exit Pendle lp position.
        outAmount = _exitPendle(
            router,
            isPt,
            token,
            data,
            zapData,
            swapData,
            recipient
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Withdraws a Curvance Pendle market position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitPendle(
        address router,
        bool isPt,
        address token,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit Pendle market position.
        PendleLib.exitPendle(
            router,
            isPt,
            token,
            data,
            zapData.inputToken,
            zapData.inputAmount,
            0
        );

        uint256 numTokenSwaps = swapData.length;
        // Swap unwrapped tokens into `zapData.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapData.outputToken`.
            SwapperLib.swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib.getTokenBalance(zapData.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapData.minimumOut) {
            revert PendleZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapData.outputToken, recipient, outAmount);
    }

    /// @notice Swap `inputToken` into desired pToken underlying tokens.
    /// @param inputToken The input token address.
    /// @param inputAmount The amount of `inputToken` to swap for underlying
    ///                    tokens.
    /// @param swapData Array of swap instruction data
    /// @param depositAsWrappedNative Used when `inputToken` is chain gas token,
    ///                           indicates depositing gas token into wrapper
    ///                           contract.
    function _swapForUnderlyings(
        address inputToken,
        uint256 inputAmount,
        SwapperLib.Swap[] memory swapData,
        bool depositAsWrappedNative
    ) internal {
        _prepareSwap(inputToken, inputAmount, depositAsWrappedNative);

        uint256 numTokenSwaps = swapData.length;
        // Swap `inputToken` into desired pToken underlying tokens.
        for (uint256 i; i < numTokenSwaps; ) {
            if (
                CommonLib.isETH(swapData[i].inputToken) &&
                depositAsWrappedNative
            ) {
                // Switch inputToken to wrapped native token address.
                swapData[i].inputToken = address(wrappedNative);
            }

            // Execute swap into underlying(s).
            SwapperLib.swapUnsafe(centralRegistry, swapData[i++]);
        }
    }
}
