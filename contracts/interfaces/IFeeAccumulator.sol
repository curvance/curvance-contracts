// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

struct EpochRolloverData {
    uint256 chainId;
    uint256 value;
    uint256 numChainData;
    uint256 epoch;
}

struct LockData {
    uint224 lockAmount;
    uint16 epoch;
    uint16 chainId;
}

interface IFeeAccumulator {
    /// @notice Updates to new messaging hub and moves fee token approval
    function notifyUpdatedMessagingHub() external;

    /// @notice Sends collected fee tokens ex compounding bot stipend to the
    ///         Protocol Messaging Hub.
    /// @dev Only callable by the Protocol Messaging Hub. Does not fail if fees
    ///      collected equal 0.
    /// @param amount The amount of token to transfer.
    /// @return The amount of transferred fee tokens to the Protocol Messaging Hub.
    function pullFees(uint256 amount) external returns (uint256);
}
