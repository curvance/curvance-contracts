// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IDiaOracle {
    function getValue(
        string memory key
    ) external view returns (uint128, uint128);
}
