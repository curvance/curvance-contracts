// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";

interface IVeCVE {
    /// @notice Locks a given amount of cve tokens on behalf of another user,
    ///         and processes any pending rewards.
    /// @param recipient The address to lock tokens for.
    /// @param amount The amount of tokens to lock.
    /// @param continuousLock Indicator of whether the lock should be continuous.
    /// @param action Rewards data for desired Reward Manager action.
    /// @param params Parameters for rewards claim function.
    /// @param aux Auxiliary data.
    function createLockFor(
        address recipient,
        uint256 amount,
        bool continuousLock,
        ClaimAction memory action,
        bytes memory params,
        uint256 aux
    ) external;

    /// @notice Increases the locked amount and extends the lock
    ///         for the specified lock index, and processes any pending
    ///         rewards.
    /// @param recipient The address to lock and extend tokens for.
    /// @param amount The amount to increase the lock by.
    /// @param lockIndex The index of the lock to extend.
    /// @param continuousLock Whether the lock should be continuous or not.
    /// @param action Rewards data for desired Reward Manager action.
    /// @param params Parameters for rewards claim function.
    /// @param aux Auxiliary data.
    function increaseAmountAndExtendLockFor(
        address recipient,
        uint256 amount,
        uint256 lockIndex,
        bool continuousLock,
        ClaimAction memory action,
        bytes memory params,
        uint256 aux
    ) external;

    /// @notice Processes reward manager fee re-investment into a current
    ///         or new lock for `recipient`.
    /// @dev Emits a {Locked} event.
    /// @param recipient The address to lock CVE tokens for.
    /// @param amount The amount of CVE to lock.
    /// @param lockIndex The index of the lock to extend (if increasing
    ///                  a lock).
    /// @param isFreshLock A boolean to indicate if a new lock is being
    ///                    created or not.
    /// @param isContinuousLock Whether the lock should be continuous or not.
    function compoundRewardsIntoLock(
        address recipient,
        uint256 amount,
        uint256 lockIndex,
        bool isFreshLock,
        bool isContinuousLock
    ) external;

    /// @notice Used for frontend, needed due to array of structs.
    /// @param user The user to query veCVE locks for.
    /// @return Unwrapped user lock information.
    function queryUserLocks(
        address user
    ) external view returns (uint256[] memory, uint256[] memory);

    /// @notice Returns the current epoch for the given time.
    /// @param time The timestamp for which to calculate the epoch.
    /// @return The current epoch.
    function currentEpoch(uint256 time) external view returns (uint256);

    /// @notice Returns the chain's current token points for
    function chainPoints() external view returns (uint256);

    /// @notice Returns the chain's token unlocks for an epoch.
    /// @param epoch The epoch to query token unlocks for.
    function chainUnlocksByEpoch(
        uint256 epoch
    ) external view returns (uint256);

    /// @notice Token Points on this chain.
    /// @param user User to query points for.
    function userPoints(address user) external view returns (uint256);

    /// @notice Returns a user's token unlocks for an epoch.
    /// @param user User to query token unlocks for.
    /// @param epoch The epoch to query token unlocks for.
    function userUnlocksByEpoch(
        address user,
        uint256 epoch
    ) external view returns (uint256);

    /// @notice Updates user points by reducing the amount that gets unlocked
    ///         in a specific epoch.
    /// @param user The address of the user whose points are to be updated.
    /// @param epoch The epoch from which the unlock amount will be reduced.
    /// @dev This function is only called when
    ///      userUnlocksByEpoch[user][epoch] > 0
    ///      so we do not need to check here.
    function updateUserPoints(address user, uint256 epoch) external;

    /// @notice Updates chain points by reducing the amount that gets unlocked
    ///         in a specific epoch.
    /// @param epoch The epoch from which the unlock amount will be reduced.
    /// @dev This function is only called when chainUnlocksByEpoch[epoch] > 0
    ///      so we do not need for equal 0 here.
    function updateChainPoints(uint256 epoch) external;

    /// @notice Returns the timestamp of when the next epoch begins.
    /// @return The calculated next epoch start timestamp.
    function nextEpochStartTime() external view returns (uint256);
}
