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
}
