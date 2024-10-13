// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPluginDelegable {
    function isDelegate(
        address user,
        address delegate
    ) public view returns (bool);
}
