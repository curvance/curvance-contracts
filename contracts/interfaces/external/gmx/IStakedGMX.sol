// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IStakedGMX {
    function updateRewards() external;

    function stakedAmounts(address) external view returns (uint256);

    function claimable(address) external view returns (uint256);
}
