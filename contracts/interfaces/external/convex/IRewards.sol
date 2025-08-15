// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IRewards {
    function rewardToken() external view returns (address);

    function getReward() external;
}
