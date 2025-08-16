// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IStakedFrax {
    function pricePerShare() external view returns (uint256);
}
