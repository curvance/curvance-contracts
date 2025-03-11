// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IActionRegistry {
    /// @notice Checks whether `user` has transferability enabled for
    ///         their tokens.
    function checkTransfersDisabled(address user) external view returns (bool);
}
