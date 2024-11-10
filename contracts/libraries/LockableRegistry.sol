// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Curvance Lockable Registry.
/// @notice Facilitates locking a users token transferrability as a secondary
///         protective layer against phishing attempts.
/// @dev `LockableRegistry` allows the Curvance Protocol, and any external
///      integrator to add an additional protective layer against phishing
///      attempts. Integrations add an external call increasing transfer calls
///      by approximately 2.5k gas, increasing costs by approximately 3.5%
///      for well optimized ERC20 implementations.
abstract contract LockableRegistry {
    /// TYPES ///
    struct TransferConfig {
        uint208 transferCooldown;
        uint40 transferEnabledTimestamp;
        bool transferDisabled;
    }

    /// CONSTANTS ///

    /// @notice Maximum lock duration enforced onchain of 1 year to prevent
    ///         accidently locking your tokens until the heat death of the
    ///         universe.
    uint256 public constant COOLDOWN_MAXIMUM = 52 weeks;

    /// STORAGE ///

    mapping(address => TransferConfig) internal userTransferConfig;

    /// EVENTS ///

    event CooldownSet(address indexed user, uint256 userLockCooldown);
    event LockStatusChanged(address indexed user, bool isLocked);

    /// ERRORS ///

    error LockableRegistry__InvalidParams();
    error LockableRegistry__UnsafeCooldown();
    error LockableRegistry__TransferDisabled();

    /// CONSTRUCTOR ///

    constructor() {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks whether `user` has their tokens transferrability locked.
    /// @param user The address to check whether transferrability is disabled.
    /// @return Returns whether `user` has their token transferrability locked.
    function lockEnabled(address user) public view returns (bool) {
        return !userTransferConfig[user].transferDisabled;
    }

    /// @notice Sets token transferrability unlock cooldown.
    /// @dev Emits a {CooldownSet} event. If a user is decreasing their cooldown,
    ///      transferrability cooldown will automatically apply, delaying when
    ///      transferrability can be re-enabled, preventing a malicious party
    ///      from tracking a user to decrease their cooldown to 0 and then enabling
    ///      transferrability.
    /// @param cooldown The length of time transferrability should remain
    ///                 restricted after their transfer lock has been disabled,
    ///                 in seconds.
    function setCooldown(uint256 cooldown) external {
        if (cooldown > COOLDOWN_MAXIMUM) {
            revert LockableRegistry__UnsafeCooldown();
        }

        TransferConfig storage userConfig = userTransferConfig[msg.sender];

        // If a user is decreasing their cooldown, transferrability cooldown
        // will automatically apply, delaying when transferrability can be
        // re-enabled, preventing a malicious party from tracking a user to
        // decrease their cooldown to 0 and then enabling transferrability.
        if (userConfig.transferCooldown > cooldown) {
            userConfig.transferEnabledTimestamp =
                uint40(userConfig.transferCooldown + block.timestamp);
        }

        userConfig.transferCooldown = uint208(cooldown);
        emit CooldownSet(msg.sender, cooldown);
    }

    /// @notice Sets token transferrability for the caller, if enabling transferrability,
    ///         the caller's opt in transfer cooldown will be applied.
    /// @dev Emits a {LockStatusChanged} event.
    /// @param transferDisabled Whether the user intends on enabling or disabling
    ///                         transferrability, while flipping their transferrability
    ///                         status can be assumed, its best to make sure the caller
    ///                         intends on flipping their status for onchain integrators.
    function setTransferLockStatus(bool transferDisabled) external {
        TransferConfig memory userConfig = userTransferConfig[msg.sender];

        // Validates that user is intending on flipping their transfer
        // lock status, even though we could assume they want to flip
        // by calling this function, it helps to validate for human error.
        if (transferDisabled == userConfig.transferDisabled) {
            revert LockableRegistry__InvalidParams();
        }

        // If the user is trying to enable transferrability again,
        // add their cooldown period, an added layer against phishing
        // attempts.
        if (!transferDisabled) {
            // Validate the user did not recently reduce their cooldown,
            // triggering their transfer cooldown.
            if (userConfig.transferEnabledTimestamp > block.timestamp) {
                revert LockableRegistry__InvalidParams();
            }

            userConfig.transferEnabledTimestamp =
                uint40(userConfig.transferCooldown + block.timestamp);
        }

        userConfig.transferDisabled = transferDisabled;

        emit LockStatusChanged(msg.sender, transferDisabled);
    }

    /// @notice Checks whether `user` has transferrability enabled for
    ///         their tokens.
    /// @dev Reverts if the user does not have transferrability enabled.
    function checkTransferrability(address user) external view {
        TransferConfig memory userConfig = userTransferConfig[user];
        if (
            userConfig.transferDisabled ||
            userConfig.transferEnabledTimestamp > block.timestamp
            ) {
                revert LockableRegistry__TransferDisabled();
        }
    }
}
