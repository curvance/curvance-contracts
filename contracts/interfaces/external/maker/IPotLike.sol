// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IPotLike {
    function chi() external view returns (uint256);

    function dsr() external view returns (uint256);

    function rho() external view returns (uint256);

    function pie(address) external view returns (uint256);

    function drip() external returns (uint256);

    function join(uint256) external;

    function exit(uint256) external;
}
