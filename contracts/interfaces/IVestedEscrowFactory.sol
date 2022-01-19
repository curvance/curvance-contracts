// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IVestedEscrowFactory {
    function createEscrow(
        address _token,
        uint256 _startTime,
        uint256 _endTime,
        address _stakeContract
    ) external;

    function getEscrows() external view returns (address[] memory);

    function owner() external returns (address);
}
