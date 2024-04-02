// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuard.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry, WormholeData } from "contracts/interfaces/ICentralRegistry.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";
import { IWormholeRelayer } from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";
import { ITokenMessenger } from "contracts/interfaces/external/wormhole/ITokenMessenger.sol";
import { ITokenBridge } from "contracts/interfaces/external/wormhole/ITokenBridge.sol";

contract FeeTokenBridgingHub is ReentrancyGuard {
    /// CONSTANTS ///

    /// @notice Gas limit with which to call `targetAddress` via wormhole.
    uint256 internal constant _DEFAULT_GAS_LIMIT = 250_000;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice Address of fee token.
    address public immutable feeToken;

    /// ERRORS ///

    error FeeTokenBridgingHub__InvalidCentralRegistry();
    error FeeTokenBridgingHub__InsufficientGasToken();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert FeeTokenBridgingHub__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;

        feeToken = centralRegistry.feeToken();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         deposit and messaging.
    /// @param dstChainId GETH destination chain ID.
    /// @param transferToken Whether deliver token or not.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Total gas cost to send a message to `dstChainId`.
    function quoteMessageFee(
        uint256 dstChainId,
        bool transferToken,
        uint256 gasLimit
    ) external view returns (uint256) {
        return _quoteMessageFee(dstChainId, transferToken, gasLimit);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param dstChainId GETH destination chain ID.
    /// @param to The address of receiver on `dstChainId`.
    /// @param amount The amount of token to transfer.
    /// @param payload The payload data that is sent along with the message.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _sendFeeToken(
        uint256 dstChainId,
        address to,
        uint256 amount,
        bytes memory payload,
        uint256 gasLimit
    ) internal {
        uint256 wormholeFee = _quoteMessageFee(dstChainId, true, gasLimit);

        // Validate that we have sufficient fees to send crosschain.
        if (address(this).balance < wormholeFee) {
            revert FeeTokenBridgingHub__InsufficientGasToken();
        }

        ITokenMessenger circleTokenMessenger = centralRegistry
            .circleTokenMessenger();

        if (payload.length == 0) {
            payload = abi.encode(uint8(1), feeToken, amount);
        }

        if (
            address(circleTokenMessenger) != address(0) &&
            circleTokenMessenger.remoteTokenMessengers(
                centralRegistry.cctpDomain(dstChainId)
            ) !=
            bytes32(0)
        ) {
            _transferFeeTokenViaCCTP(
                circleTokenMessenger,
                dstChainId,
                to,
                amount,
                payload,
                wormholeFee,
                gasLimit
            );
        } else {
            _transferTokenViaWormhole(
                feeToken,
                dstChainId,
                to,
                amount,
                payload,
                wormholeFee,
                gasLimit
            );
        }
    }

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param circleTokenMessenger Token Messenger contract to submit
    ///                             transfer message to.
    /// @param dstChainId GETH destination chain ID.
    /// @param to The address of receiver on `dstChainId`.
    /// @param amount The amount of token to transfer.
    /// @param payload The payload data that is sent along with the message.
    /// @param wormholeFee Total gas cost to attach send a CCTP message
    ///                    to `dstChainId`.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _transferFeeTokenViaCCTP(
        ITokenMessenger circleTokenMessenger,
        uint256 dstChainId,
        address to,
        uint256 amount,
        bytes memory payload,
        uint256 wormholeFee,
        uint256 gasLimit
    ) internal {
        IWormholeRelayer wormholeRelayer = centralRegistry.wormholeRelayer();
        WormholeData memory wormholeData = centralRegistry.wormholeData(
            dstChainId
        );

        SwapperLib._approveTokenIfNeeded(
            feeToken,
            address(circleTokenMessenger),
            amount
        );

        uint64 nonce = circleTokenMessenger.depositForBurnWithCaller(
            amount,
            centralRegistry.cctpDomain(dstChainId),
            bytes32(uint256(uint160(to))),
            feeToken,
            bytes32(uint256(uint160(wormholeData.relayer)))
        );

        IWormholeRelayer.MessageKey[]
            memory messageKeys = new IWormholeRelayer.MessageKey[](1);
        messageKeys[0] = IWormholeRelayer.MessageKey(
            2, // CCTP_KEY_TYPE
            abi.encodePacked(centralRegistry.cctpDomain(block.chainid), nonce)
        );

        address defaultDeliveryProvider = wormholeRelayer
            .getDefaultDeliveryProvider();

        wormholeRelayer.sendToEvm{ value: wormholeFee }(
            wormholeData.chainId,
            to,
            payload,
            0,
            0,
            gasLimit > 0 ? gasLimit : _DEFAULT_GAS_LIMIT,
            wormholeData.chainId,
            address(0),
            defaultDeliveryProvider,
            messageKeys,
            15
        );
    }

    /// @notice Sends fee tokens to the receiver on `dstChainId`.
    /// @param token The address of the token to transfer via Wormhole.
    /// @param dstChainId GETH destination chain ID.
    /// @param to The address of receiver on `dstChainId`.
    /// @param amount The amount of token to transfer.
    /// @param payload The payload data that is sent along with the message.
    /// @param wormholeFee Total gas cost to attach send a Wormhole message
    ///                    to `dstChainId`.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function _transferTokenViaWormhole(
        address token,
        uint256 dstChainId,
        address to,
        uint256 amount,
        bytes memory payload,
        uint256 wormholeFee,
        uint256 gasLimit
    ) internal returns (uint64) {
        ITokenBridge tokenBridge = centralRegistry.tokenBridge();
        IWormhole wormholeCore = centralRegistry.wormholeCore();
        uint16 wormholeChainId = centralRegistry
            .wormholeData(dstChainId)
            .chainId;

        SwapperLib._approveTokenIfNeeded(token, address(tokenBridge), amount);

        uint64 sequence = tokenBridge.transferTokensWithPayload{
            value: wormholeCore.messageFee()
        }(
            token,
            amount,
            wormholeChainId,
            bytes32(uint256(uint160(to))),
            0,
            payload
        );

        if (payload.length > 0) {
            IWormholeRelayer.VaaKey[]
                memory vaaKeys = new IWormholeRelayer.VaaKey[](1);
            vaaKeys[0] = IWormholeRelayer.VaaKey({
                emitterAddress: bytes32(
                    uint256(uint160(address(tokenBridge)))
                ),
                chainId: wormholeCore.chainId(),
                sequence: sequence
            });

            return
                centralRegistry.wormholeRelayer().sendVaasToEvm{
                    value: wormholeFee - wormholeCore.messageFee()
                }(
                    wormholeChainId,
                    to,
                    payload,
                    0,
                    gasLimit > 0 ? gasLimit : _DEFAULT_GAS_LIMIT,
                    vaaKeys
                );
        }
    }

    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         deposit and messaging.
    /// @param dstChainId GETH destination chain ID.
    /// @param transferToken Whether deliver token or not.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return nativeFee Total gas cost.
    function _quoteMessageFee(
        uint256 dstChainId,
        bool transferToken,
        uint256 gasLimit
    ) internal view returns (uint256 nativeFee) {
        (nativeFee, ) = centralRegistry
            .wormholeRelayer()
            .quoteEVMDeliveryPrice(
                centralRegistry.wormholeData(dstChainId).chainId,
                0,
                gasLimit > 0 ? gasLimit : _DEFAULT_GAS_LIMIT
            );

        if (transferToken) {
            // Add cost of publishing the 'sending token' wormhole message.
            nativeFee += centralRegistry.wormholeCore().messageFee();
        }
    }
}
