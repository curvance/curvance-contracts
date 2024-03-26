// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IProtocolMessagingHub {
    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         wormhole deposit and messaging.
    /// @param dstChainId Destination chain ID.
    /// @param transferToken Whether deliver token or not.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Total gas cost.
    function quoteWormholeFee(
        uint256 dstChainId,
        bool transferToken,
        uint256 gasLimit
    ) external view returns (uint256);

    /// @notice Sends veCVE locked token data to destination chain.
    /// @param dstChainId Destination chain ID where the message data should be
    ///                   sent.
    /// @param toAddress The destination address specified by `dstChainId`.
    /// @param payload The payload data that is sent along with the message.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @dev We redundantly pass adapterParams so we do not need to coerce data
    ///      in the function, calls with this function will have
    ///      messageType = 1, 2 or 3
    function sendWormholeMessages(
        uint256 dstChainId,
        address toAddress,
        bytes calldata payload,
        uint256 gasLimit
    ) external payable;

    /// @notice Sends fee tokens to the Messaging Hub on `dstChainId`.
    /// @param dstChainId Destination chain ID .
    /// @param to The address of Messaging Hub on `dstChainId`.
    /// @param amount The amount of token to transfer.
    /// @param gasLimit Gas limit with which to call on destination chain.
    function sendFees(
        uint256 dstChainId,
        address to,
        uint256 amount,
        uint256 gasLimit
    ) external;

    /// @notice Bridge CVE to destination chain.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param recipient The address of recipient on destination chain.
    /// @param amount The amount of token to bridge.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Wormhole sequence for emitted TransferTokensWithRelay message.
    function bridgeCVE(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        uint256 gasLimit
    ) external payable returns (uint64);

    /// @notice Bridge VeCVE lock to destination chain.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param recipient The address of recipient on destination chain.
    /// @param amount The amount of token to bridge.
    /// @param continuousLock Whether the lock should be continuous or not.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Wormhole sequence for emitted TransferTokensWithRelay message.
    function bridgeVeCVELock(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        bool continuousLock,
        uint256 gasLimit
    ) external payable returns (uint64);

    /// @notice Returns required amount of native asset for message fee.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Required fee.
    function cveBridgeFee(
        uint256 dstChainId,
        uint256 gasLimit
    ) external view returns (uint256);
}
