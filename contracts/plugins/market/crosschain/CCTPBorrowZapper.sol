// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry, ChainData } from "contracts/interfaces/ICentralRegistry.sol";

import { ITokenMessenger } from "contracts/interfaces/external/wormhole/ITokenMessenger.sol";
import { IWormholeRelayer } from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";

contract CCTPBorrowZapper is ReentrancyGuard {
    /// CONSTANTS ///

    /// @notice Gas limit with which to call `targetAddress` crosschain.
    uint256 internal constant _DEFAULT_GAS_LIMIT = 300_000;
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// ERRORS ///

    error CCTPBorrowZapper__InvalidSwapAction();
    error CCTPBorrowZapper__InsufficientGasToken();
    error CCTPBorrowZapper__CCTPIsNotConfigured();

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(ICentralRegistry centralRegistry_) {
        CentralRegistryLib._isCentralRegistry(centralRegistry_);
        centralRegistry = centralRegistry_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Borrows on behalf of the caller from `borrowableCToken` then
    ///         bridge funds to desired destination chain.
    /// @dev Requires that caller delegated borrowing functionality to this
    ///      contract prior.
    /// @param borrowableCToken The Curvance token contract address to borrow
    ///                         from.
    /// @param borrowAmount The amount of `borrowableCToken` asset to
    ///                     borrow.
    /// @param swapAction Instructions for a swap action containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @param dstChainId Chain ID of the target blockchain.
    function borrowAndBridge(
        address borrowableCToken,
        uint256 borrowAmount,
        SwapperLib.Swap memory swapAction,
        uint256 dstChainId,
        uint256 gasLimit
    ) external payable nonReentrant {
        address feeToken = centralRegistry.feeToken();
        uint256 balancePrior = IERC20(feeToken).balanceOf(address(this));

        // Borrow on behalf of caller.
        IBorrowableCToken(borrowableCToken).borrowFor(
            borrowAmount,
            address(this),
            msg.sender
        );

        address asset = IBorrowableCToken(borrowableCToken).asset();

        // Check if swapping is necessary.
        if (asset != feeToken) {
            if (
                swapAction.target == address(0) ||
                swapAction.inputToken != asset ||
                swapAction.outputToken != feeToken ||
                swapAction.inputAmount != borrowAmount
            ) {
                revert CCTPBorrowZapper__InvalidSwapAction();
            }

            SwapperLib._swapUnsafe(centralRegistry, swapAction);
        } else if (swapAction.target != address(0)) {
            revert CCTPBorrowZapper__InvalidSwapAction();
        }

        // Bridge the fee token to `dstChainId` via Wormhole.
        _sendFeeToken(
            dstChainId,
            IERC20(feeToken).balanceOf(address(this)) - balancePrior,
            gasLimit
        );
    }

    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         deposit and messaging.
    /// @param dstChainId GETH destination chain ID.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Total gas cost to send a message to `dstChainId`.
    function quoteMessageFee(
        uint256 dstChainId,
        uint256 gasLimit
    ) external view returns (uint256) {
        return _quoteMessageFee(dstChainId, gasLimit);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param dstChainId GETH destination chain ID.
    /// @param amount The amount of token to transfer.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _sendFeeToken(
        uint256 dstChainId,
        uint256 amount,
        uint256 gasLimit
    ) internal {
        ITokenMessenger tokenMessager = ITokenMessenger(
            centralRegistry.tokenMessager()
        );

        if (
            address(tokenMessager) != address(0) &&
            tokenMessager.remoteTokenMessengers(
                centralRegistry.supportedChainData(dstChainId).domain
            ) !=
            bytes32(0)
        ) {
            _transferFeeTokenViaCCTP(
                tokenMessager,
                dstChainId,
                amount,
                gasLimit
            );
        } else {
            revert CCTPBorrowZapper__CCTPIsNotConfigured();
        }
    }

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param tokenMessager Token Messenger contract to submit transfer
    ///                      message to.
    /// @param dstChainId GETH destination chain ID.
    /// @param amount The amount of token to transfer.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _transferFeeTokenViaCCTP(
        ITokenMessenger tokenMessager,
        uint256 dstChainId,
        uint256 amount,
        uint256 gasLimit
    ) internal {
        uint256 wormholeFee = _quoteMessageFee(dstChainId, gasLimit);

        // Validate that we have sufficient fees to send crosschain.
        if (msg.value < wormholeFee) {
            revert CCTPBorrowZapper__InsufficientGasToken();
        }

        IWormholeRelayer crosschainRelayer = _getCrosschainRelayer();
        ChainData memory chainData = centralRegistry.supportedChainData(
            dstChainId
        );

        address feeToken = centralRegistry.feeToken();
        SwapperLib._approveIfNeeded(
            feeToken,
            address(tokenMessager),
            amount
        );

        uint64 nonce = tokenMessager.depositForBurnWithCaller(
            amount,
            chainData.domain,
            bytes32(uint256(uint160(msg.sender))),
            feeToken,
            bytes32(uint256(uint160(chainData.crosschainRelayer)))
        );

        IWormholeRelayer.MessageKey[]
            memory messageKeys = new IWormholeRelayer.MessageKey[](1);
        messageKeys[0] = IWormholeRelayer.MessageKey(
            2, // CCTP_KEY_TYPE
            abi.encodePacked(centralRegistry.domain(), nonce)
        );

        address defaultDeliveryProvider = crosschainRelayer
            .getDefaultDeliveryProvider();

        crosschainRelayer.sendToEvm{ value: wormholeFee }(
            chainData.messagingChainId,
            msg.sender,
            "",
            0,
            0,
            gasLimit > _DEFAULT_GAS_LIMIT ? gasLimit : _DEFAULT_GAS_LIMIT,
            chainData.messagingChainId,
            address(0),
            defaultDeliveryProvider,
            messageKeys,
            15
        );

        // Refund any remaining unused native token attached to transaction.
        uint256 remaining = msg.value - wormholeFee;
        if (remaining > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, remaining);
        }
    }

    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         deposit and messaging.
    /// @param dstChainId GETH destination chain ID.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return nativeFee Total gas cost.
    function _quoteMessageFee(
        uint256 dstChainId,
        uint256 gasLimit
    ) internal view returns (uint256 nativeFee) {
        (nativeFee, ) = _getCrosschainRelayer().quoteEVMDeliveryPrice(
            centralRegistry.supportedChainData(dstChainId).messagingChainId,
            0,
            gasLimit > _DEFAULT_GAS_LIMIT ? gasLimit : _DEFAULT_GAS_LIMIT
        );

        // Add cost of publishing the 'sending token' crosschain message.
        nativeFee += IWormhole(centralRegistry.crosschainCore()).messageFee();
    }

    /// @dev Returns the current Crosschain Relayer address to call.
    /// @return The current Crosschain Relayer contract.
    function _getCrosschainRelayer() internal view returns (IWormholeRelayer) {
        return IWormholeRelayer(centralRegistry.crosschainRelayer());
    }
}
