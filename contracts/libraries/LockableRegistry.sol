// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Curvance Lockable Registry.
/// @notice Facilitates locking a users token transferability as a secondary
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
    ///         accidentally locking your tokens until the heat death of the
    ///         universe.
    uint256 public constant COOLDOWN_MAXIMUM = 52 weeks;

    /// STORAGE ///

    mapping(address => TransferConfig) internal _userTransferConfig;

    /// EVENTS ///

    event CooldownSet(address indexed user, uint256 userLockCooldown);
    event LockStatusChanged(
        address indexed user,
        bool isLocked,
        uint256 transferEnabledTimestamp
    );

    /// ERRORS ///

    error LockableRegistry__InvalidParams();
    error LockableRegistry__UnsafeCooldown();

    /// CONSTRUCTOR ///

    constructor() {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks whether `user` has their tokens transferability locked.
    /// @param user The address to check whether transferability is disabled.
    /// @return Returns whether `user` has their token transferability locked.
    function lockEnabled(address user) public view returns (bool) {
        return !_userTransferConfig[user].transferDisabled;
    }

    /// @notice Sets token transferability unlock cooldown.
    /// @dev Emits a {CooldownSet} event. If a user is decreasing their cooldown,
    ///      transferability cooldown will automatically apply, delaying when
    ///      transferability can be re-enabled, preventing a malicious party
    ///      from tracking a user to decrease their cooldown to 0 and then enabling
    ///      transferability.
    /// @param cooldown The length of time transferability should remain
    ///                 restricted after their transfer lock has been disabled,
    ///                 in seconds.
    function setCooldown(uint256 cooldown) external {
        if (cooldown > COOLDOWN_MAXIMUM) {
            revert LockableRegistry__UnsafeCooldown();
        }

        TransferConfig storage userConfig = _userTransferConfig[msg.sender];

        // If a user is decreasing their cooldown, transferability cooldown
        // will automatically apply, delaying when transferability can be
        // re-enabled, preventing a malicious party from tracking a user to
        // decrease their cooldown to 0 and then enabling transferability.
        if (userConfig.transferCooldown > cooldown) {
            userConfig.transferEnabledTimestamp = uint40(
                userConfig.transferCooldown + block.timestamp
            );
        }

        userConfig.transferCooldown = uint208(cooldown);
        emit CooldownSet(msg.sender, cooldown);
    }

    /// @notice Sets token transferability for the caller, if enabling
    ///         transferability, the caller's opt in transfer cooldown will
    ///         be applied.
    /// @dev Emits a {LockStatusChanged} event.
    /// @param transferDisabled Whether the user intends on enabling or
    ///                         disabling transferability, while flipping
    ///                         their transferability status can be assumed,
    ///                         it's best to make sure the caller intends on
    ///                         flipping their status for onchain integrators.
    function setTransferLockStatus(bool transferDisabled) external {
        TransferConfig storage userConfig = _userTransferConfig[msg.sender];

        // Validates that user is intending on flipping their transfer
        // lock status, even though we could assume they want to flip
        // by calling this function, it helps to validate for human error.
        if (transferDisabled == userConfig.transferDisabled) {
            revert LockableRegistry__InvalidParams();
        }

        uint256 enableTimestamp;

        // If the user is trying to enable transferability again,
        // add their cooldown period, an added layer against phishing
        // attempts.
        if (!transferDisabled) {
            // Validate the user did not recently reduce their cooldown,
            // triggering their transfer cooldown.
            if (userConfig.transferEnabledTimestamp > block.timestamp) {
                revert LockableRegistry__InvalidParams();
            }
            enableTimestamp = userConfig.transferCooldown + block.timestamp;
            userConfig.transferEnabledTimestamp = uint40(enableTimestamp);
        }

        userConfig.transferDisabled = transferDisabled;

        // Timestamp emitted is 0 if locking transferability.
        emit LockStatusChanged(msg.sender, transferDisabled, enableTimestamp);
    }

    /// @notice Checks whether `user` has transferability enabled or disabled
    ///         for their tokens.
    /// @return Returns true if the user has transferability disabled.
    function checkTransfersDisabled(
        address user
    ) external view returns (bool) {
        TransferConfig memory userConfig = _userTransferConfig[user];
        return (userConfig.transferDisabled ||
            userConfig.transferEnabledTimestamp > block.timestamp);
    }
}
