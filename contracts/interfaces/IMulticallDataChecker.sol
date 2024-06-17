// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IMulticallDataChecker {
    function checkCallData(
        address caller,
        address target,
        bytes memory data
    ) external;
}
