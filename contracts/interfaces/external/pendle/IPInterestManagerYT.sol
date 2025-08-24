// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IPInterestManagerYT {
    function userInterest(
        address user
    ) external view returns (uint128 lastPYIndex, uint128 accruedInterest);
}
