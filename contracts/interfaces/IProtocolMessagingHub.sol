// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { LockData } from "contracts/interfaces/IFeeAccumulator.sol";

interface IProtocolMessagingHub {
    /// @notice Quotes gas cost and token fee for executing crosschain
    ///         deposit and messaging.
    /// @param dstChainId Destination chain ID.
    /// @param transferToken Whether deliver token or not.
    /// @param gasLimit Gas limit with which to call on destination chain.
    /// @return Total gas cost.
    function quoteMessageFee(
        uint256 dstChainId,
        bool transferToken,
        uint256 gasLimit
    ) external view returns (uint256);

    /// @notice Records a Curvance reward epoch, if all chains have been
    ///         recorded executes system wide reporting and distribution
    ///         to all chains within the Curvance Protocol system.
    function sendEpochRewardData(
        LockData[] memory crossChainLockData,
        uint256 epochRewardsPerCVE,
        uint256 gasLimit
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
}
