// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @param gaugePools The gauge pool contract addresses that emission data
///                   corresponds to.
/// @param emissionTotals The total amount of token emissions to allocate
///                       to the gauge pools.
/// @param tokens The token contract addresses receiving emissions.
/// @param emissions The emission amounts that each token should receive.
struct EmissionData {
    address[] gaugePools;
    uint256[] emissionTotals;
    address[][] tokens;
    uint256[][] emissions;
}

interface IMessagingHub {
    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         wormhole deposit and messaging.
    /// @param dstChainId Destination chain ID.
    /// @param transferToken Whether deliver token or not.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Total gas cost.
    function quoteMessageFee(
        uint256 dstChainId,
        bool transferToken,
        uint256 gasLimit
    ) external view returns (uint256);

    /// @notice Sends token emissions configuration to the Messaging Hub
    ///         on `dstChainId`.
    /// @param emissionData Struct containing information on emission
    ///                     configuration.
    ///                     Containing values:
    ///                     1. The gauge pool contract addresses that emission
    ///                        data corresponds to.
    ///                     2. The total amount of token emissions to allocate
    ///                        to the gauge pools.
    ///                     3. The token contract addresses receiving
    ///                        emissions.
    ///                     4. The emission amounts that each token should
    ///                        receive.
    /// @param dstChainId The remote chain's ID that will have its token
    ///                   emissions values set, in GETH format.
    /// @param gasLimit Gas limit value for each remote chain message,
    ///                 0 = default value inside messaging hub.
    /// @param epoch The epoch having its token emission values set.
    function sendEmissions(
        EmissionData calldata emissionData,
        uint256 dstChainId,
        uint256 gasLimit,
        uint256 epoch
    ) external;

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

    /// @notice Send CVE or a veCVE lock via Wormhole.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param recipient The address of recipient on destination chain.
    /// @param amount The amount of token to bridge.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @param payloadType The type of payload information to relay to destination chain.
    ///                    VeCVE lock migrations have a payloadType of 4, whereas CVE
    ///                    has no payload type because its a native transfer.
    /// @param aux Auxilliary boolean data if needed for bridging token.
    /// @return Wormhole sequence for emitted TransferTokensWithRelay message.
    function bridgeToken(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        uint256 gasLimit,
        uint256 payloadType,
        bool aux
    ) external payable returns (uint64);
}
