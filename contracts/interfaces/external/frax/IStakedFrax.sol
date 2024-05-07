// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IStakedFrax {
    function pricePerShare() external view returns (uint256);
}
