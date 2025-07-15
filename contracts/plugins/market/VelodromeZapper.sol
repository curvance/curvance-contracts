// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ZapperBase, ICentralRegistry } from "contracts/plugins/ZapperBase.sol";

import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";

contract VelodromeZapper is ZapperBase {
    /// TYPES ///

    /// @title Velodrome Zapper Data
    /// @param inputToken Address of input token to Zap from.
    /// @param inputAmount The amount of `inputToken` to Zap.
    /// @param outputToken Address of token Zapped into.
    /// @param minimumOut The minimum amount of `outputToken` acceptable
    ///                   from the Zap.
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    struct ZapperData {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 minimumOut;
        bool depositAsWrappedNative;
    }

    /// ERRORS ///

    error VelodromeZapper__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) ZapperBase(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapData.inputToken`, into Velodrome,
    ///         and enters into a Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param strategyCToken The Curvance token address to enter a
    ///                       position in.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param router The Velodrome router address.
    /// @param factory The Velodrome factory address.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of
    ///                       `swapData.outputToken` into `strategyCToken`
    ///                       position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param receiver Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterVelodrome(
        address strategyCToken,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address router,
        address factory,
        uint256 expectedShares,
        bool collateralize,
        address receiver
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapData.inputToken,
            zapData.inputAmount,
            swapData,
            zapData.depositAsWrappedNative
        );

        // Enter Velodrome position.
        outAmount = VelodromeLib._enterVelodrome(
            router,
            factory,
            zapData.outputToken,
            CommonLib._getTokenBalance(IVeloPair(zapData.outputToken).token0()),
            CommonLib._getTokenBalance(IVeloPair(zapData.outputToken).token1()),
            zapData.minimumOut
        );

        // Enter Curvance position.
        outAmount = _enterCurvance(
            strategyCToken,
            zapData.outputToken,
            outAmount,
            expectedShares,
            collateralize,
            receiver
        );
    }

    /// @notice Exits a Velodrome position, and zaps it into desired
    ///         token (zapData.outputToken).
    /// @param router The Velodrome router address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitVelodrome(
        address router,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Velodrome sAMM/vAMM to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapData.inputToken,
            msg.sender,
            address(this),
            zapData.inputAmount
        );

        // Exit Velodrome position.
        outAmount = _exitVelodrome(router, zapData, swapData, receiver);
    }

    /// @notice Withdraws from a Curvance Velodrome position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param redemptionData Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the strategyCToken
    ///                          corresponding to Velodrome token to be
    ///                          exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param router The Velodrome router address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitVelodrome(
        RedemptionData calldata redemptionData,
        address router,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address receiver
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redemptionData.cToken,
            zapData.inputToken,
            redemptionData.shares,
            zapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            receiver
        );

        // Exit Velodrome position.
        outAmount = _exitVelodrome(router, zapData, swapData, receiver);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Withdraws from a Curvance Velodrome position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param router The Velodrome router address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param receiver Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitVelodrome(
        address router,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address receiver
    ) internal returns (uint256 outAmount) {
        // Exit Velodrome position.
        VelodromeLib._exitVelodrome(
            router,
            zapData.inputToken,
            zapData.inputAmount
        );

        uint256 numTokenSwaps = swapData.length;
        // Swap unwrapped tokens into `zapData.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapData.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib._getTokenBalance(zapData.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapData.minimumOut) {
            revert VelodromeZapper__SlippageError();
        }

        // Transfer output tokens to `receiver`.
        _transferToRecipient(zapData.outputToken, receiver, outAmount);
    }

    /// @notice Swap `inputToken` into desired underlying tokens.
    /// @param inputToken The input token address.
    /// @param inputAmount The amount of `inputToken` to swap for underlying
    ///                    tokens.
    /// @param swapData Array of swap instruction data
    /// @param depositAsWrappedNative Used when `inputToken` is the native gas
    ///                               token, indicates depositing native token
    ///                               into wrapped version or not.
    function _swapForUnderlyings(
        address inputToken,
        uint256 inputAmount,
        SwapperLib.Swap[] memory swapData,
        bool depositAsWrappedNative
    ) internal {
        _prepareSwap(inputToken, inputAmount, depositAsWrappedNative);

        uint256 numTokenSwaps = swapData.length;
        // Swap `inputToken` into desired underlying tokens.
        for (uint256 i; i < numTokenSwaps; ) {
            if (
                CommonLib._isETH(swapData[i].inputToken) &&
                depositAsWrappedNative
            ) {
                // Switch inputToken to wrapped native token address.
                swapData[i].inputToken = address(wrappedNative);
            }

            // Execute swap into underlying(s).
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }
    }
}
