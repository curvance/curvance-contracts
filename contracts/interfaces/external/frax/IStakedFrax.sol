// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IStakedFrax {
    function pricePerShare() external view returns (uint256);
}
