// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ILockableRegistry {
    /// @notice Checks whether `user` has transferrability enabled for
    ///         their tokens.
    function checkTransferrability(address user) external view;
}
