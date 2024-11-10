// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ILockableRegistry {
    /// @notice Checks whether `user` has transferability enabled for
    ///         their tokens.
    function checkTransferability(address user) external view;
}
