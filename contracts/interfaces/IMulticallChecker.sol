// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IMulticallChecker {
    function checkCalldata(
        address caller,
        address target,
        bytes memory data
    ) external;
}
