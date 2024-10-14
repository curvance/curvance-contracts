// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { EToken } from "contracts/market/token/EToken.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry, ChainData } from "contracts/interfaces/ICentralRegistry.sol";
import { ITokenMessenger } from "contracts/interfaces/external/wormhole/ITokenMessenger.sol";
import { IWormholeRelayer } from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";

contract BorrowCircleZapper is ReentrancyGuard {
    /// CONSTANTS ///

    /// @notice Gas limit with which to call `targetAddress` via wormhole.
    uint256 internal constant _DEFAULT_GAS_LIMIT = 250_000;
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Address of fee token.
    address public immutable feeToken;

    /// ERRORS ///

    error BorrowCircleZapper__InvalidCentralRegistry();
    error BorrowCircleZapper__InvalidSwapData();
    error BorrowCircleZapper__InsufficientGasToken();
    error BorrowCircleZapper__CCTPIsNotConfigured();

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert BorrowCircleZapper__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;

        feeToken = centralRegistry.feeToken();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Borrows on behalf of the caller from `eToken` then bridge
    ///         funds to desired destination chain.
    /// @dev Requires that caller delegated borrowing functionality to this
    ///      contract prior.
    /// @param eToken The eToken contract to borrow from.
    /// @param borrowAmount The amount of eToken underlying to borrow.
    /// @param swapData Swap instruction data to route from borrowed token
    ///                 to `feeToken`.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @param dstChainId Chain ID of the target blockchain.
    function borrowAndBridge(
        address eToken,
        uint256 borrowAmount,
        SwapperLib.Swap memory swapData,
        uint256 dstChainId,
        uint256 gasLimit
    ) external payable nonReentrant {
        uint256 balancePrior = IERC20(feeToken).balanceOf(address(this));

        // Borrow on behalf of caller.
        EToken(eToken).borrowFor(msg.sender, address(this), borrowAmount);

        address underlying = EToken(eToken).underlying();

        // Check if swapping is necessary.
        if (underlying != feeToken) {
            if (
                swapData.target == address(0) ||
                swapData.inputToken != underlying ||
                swapData.outputToken != feeToken ||
                swapData.inputAmount != borrowAmount
            ) {
                revert BorrowCircleZapper__InvalidSwapData();
            }

            SwapperLib.swapUnsafe(centralRegistry, swapData);
        } else if (swapData.target != address(0)) {
            revert BorrowCircleZapper__InvalidSwapData();
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
        ITokenMessenger circleTokenMessenger = centralRegistry
            .circleTokenMessenger();

        if (
            address(circleTokenMessenger) != address(0) &&
            circleTokenMessenger.remoteTokenMessengers(
                centralRegistry.supportedChainData(dstChainId).cctpDomain
            ) !=
            bytes32(0)
        ) {
            _transferFeeTokenViaCCTP(
                circleTokenMessenger,
                dstChainId,
                amount,
                gasLimit
            );
        } else {
            revert BorrowCircleZapper__CCTPIsNotConfigured();
        }
    }

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param circleTokenMessenger Token Messenger contract to submit
    ///                             transfer message to.
    /// @param dstChainId GETH destination chain ID.
    /// @param amount The amount of token to transfer.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _transferFeeTokenViaCCTP(
        ITokenMessenger circleTokenMessenger,
        uint256 dstChainId,
        uint256 amount,
        uint256 gasLimit
    ) internal {
        uint256 wormholeFee = _quoteMessageFee(dstChainId, gasLimit);

        // Validate that we have sufficient fees to send crosschain.
        if (msg.value < wormholeFee) {
            revert BorrowCircleZapper__InsufficientGasToken();
        }

        IWormholeRelayer wormholeRelayer = centralRegistry.wormholeRelayer();
        ChainData memory chainData = centralRegistry.supportedChainData(
            dstChainId
        );

        SwapperLib._approveTokenIfNeeded(
            feeToken,
            address(circleTokenMessenger),
            amount
        );

        uint64 nonce = circleTokenMessenger.depositForBurnWithCaller(
            amount,
            chainData.cctpDomain,
            bytes32(uint256(uint160(msg.sender))),
            feeToken,
            bytes32(uint256(uint160(chainData.wormholeRelayer)))
        );

        IWormholeRelayer.MessageKey[]
            memory messageKeys = new IWormholeRelayer.MessageKey[](1);
        messageKeys[0] = IWormholeRelayer.MessageKey(
            2, // CCTP_KEY_TYPE
            abi.encodePacked(centralRegistry.cctpDomain(), nonce)
        );

        address defaultDeliveryProvider = wormholeRelayer
            .getDefaultDeliveryProvider();

        wormholeRelayer.sendToEvm{ value: wormholeFee }(
            chainData.messagingChainId,
            msg.sender,
            "",
            0,
            0,
            gasLimit > 0 ? gasLimit : _DEFAULT_GAS_LIMIT,
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
        (nativeFee, ) = centralRegistry
            .wormholeRelayer()
            .quoteEVMDeliveryPrice(
                centralRegistry
                    .supportedChainData(dstChainId)
                    .messagingChainId,
                0,
                gasLimit > 0 ? gasLimit : _DEFAULT_GAS_LIMIT
            );

        // Add cost of publishing the 'sending token' wormhole message.
        nativeFee += centralRegistry.wormholeCore().messageFee();
    }
}
