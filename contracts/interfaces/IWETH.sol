//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IWETH {
    function balanceOf(address user) external view returns (uint256);

    function deposit() external payable;

    function withdraw(uint256 amount) external;
}
