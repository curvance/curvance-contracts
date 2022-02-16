// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

interface IVotingEligibility{
    function isEligible(address _account) external view returns(bool);
}