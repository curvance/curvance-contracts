// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IMulticallChecker {
    function checkCalldata(
        address caller,
        address target,
        bytes memory data
    ) external;
}
