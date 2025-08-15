// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IDelegateRegistry {
    function setDelegate(bytes32 id, address delegate) external;

    function clearDelegate(bytes32 id) external;

    function delegation(address, bytes32) external view returns (address);
}
