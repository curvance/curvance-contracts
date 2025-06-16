// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ITimelock {
    /// @notice Cancels a queued action.
    /// @dev Only callable by `CANCELLER_ROLE` or the Emergency Council.
    ///      May emit a {Cancelled} event.
    /// @param id The queued action to cancel.
    function cancel(bytes32 id) external;

    /// @notice Permissionlessly update DAO address if it has been changed.
    ///         through the Protocol Central Registry.
    function updateDaoAddress() external;

    /// @notice Updates the minimum delay between an action queue and
    ///         execution.
    /// @dev `newDelay` cannot be less than `MINIMUM_DELAY`.
    ///      May emit a {MinDelayChange} event.
    /// @param newDelay The new minimum delay between action queue and
    ///                 execution.
    function updateDelay(uint256 newDelay) external;
}
