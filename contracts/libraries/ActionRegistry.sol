// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Curvance Action Registry.
/// @notice Facilitates locking a users token transferability or plugin
///         approvals as a secondary protective layer against phishing
///         attempts.
/// @dev `ActionRegistry` enables the plugin system, a new
///      primitive allowing for "delegation" of specific actions to any
///      address, providing that address authority on behalf of the user in
///      the smart contract. Approvals can also be mass revoked via the
///      "approval index" system. By incrementing one's approval index, a user
///      can revoke all approved address' delegation privileges at the same
///      time. This facilitates better management of approvals inside
///      Curvance versus conventional implementations on top of the EVM.
///
///      Second, `ActionRegistry` enables the locking system,
///      which operates as an optional 2FA setting to reduce the potential of
///      a successful phishing attempt on a user. A cooldown can be set for
///      token transfers and plugin delegation that activates after an action
///      lock is enabled.
///
///      Integrators of the transfer lock call can expect roughly a
///      3% increase to transfer calls for optimized ERC20 implementations.
///
abstract contract ActionRegistry {
    /// TYPES ///

    /// @title User Configuration
    /// @notice Struct containing information on a user's configuration values
    ///         for transfers and delegation inside Curvance.
    /// @param lockCooldown The cooldown period for the user's transfers and
    ///                     delegations.
    /// @param transferEnabledTimestamp The timestamp that the user's
    ///                                 transfers have been enabled.
    /// @param transferDisabled Whether the user intends on enabling or
    ///                         disabling transferability
    /// @param approvalIndex The approval index for the user's delegates. Revokes
    ///                     all delegates at once if incremented.
    /// @param delegationEnabledTimestamp The timestamp that the user's
    ///                                  delegations have been enabled.
    /// @param delegationDisabled Whether the user intends on enabling or
    ///                          disabling delegation.
    struct UserConfig {
        uint208 lockCooldown;
        uint40 transferEnabledTimestamp;
        bool transferDisabled;
        uint208 approvalIndex;
        uint40 delegationEnabledTimestamp;
        bool delegationDisabled;
    }

    /// CONSTANTS ///

    /// @notice Maximum lock duration enforced onchain of 1 year to prevent
    ///         accidentally locking your tokens until the heat death of the
    ///         universe.
    uint256 public constant COOLDOWN_MAXIMUM = 52 weeks;

    /// STORAGE ///

    /// @notice Contains a user's configuration values for transfers and
    ///         delegation inside Curvance.
    /// @dev By incrementing their approval index, a user's delegates will all
    ///      have their delegation authority revoked across all Curvance
    ///      contracts. A user can apply a cooldown to their transfers and
    ///      delegations if they have enabled `lockCooldown`.
    ///      User => User configuration values.
    mapping(address => UserConfig) internal _userConfig;

    /// EVENTS ///

    event CooldownSet(address indexed user, uint256 userLockCooldown);
    event ApprovalIndexIncremented(address indexed user, uint256 newIndex);
    event DelegableStatusChanged(
        address indexed user,
        bool delegable,
        uint256 delegationEnabledTimestamp
    );
    event LockStatusChanged(
        address indexed user,
        bool isLocked,
        uint256 transferEnabledTimestamp
    );

    /// ERRORS ///

    error ActionRegistry__InvalidParams();
    error ActionRegistry__UnsafeCooldown();

    /// CONSTRUCTOR ///

    constructor() {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Sets token transferability unlock cooldown.
    /// @dev Emits a {CooldownSet} event. If a user is decreasing their
    ///      cooldown, lock cooldown will automatically apply,
    ///      delaying when transferability plugin approvals can be re-enabled,
    ///      preventing a malicious party from tracking a user to decrease
    ///      their cooldown to 0 and then phishing them.
    /// @param cooldown The length of time transferability and plugin approval
    ///                 should remain restricted after their lock has been
    ///                 disabled, in seconds.
    function setCooldown(uint256 cooldown) external {
        if (cooldown > COOLDOWN_MAXIMUM) {
            revert ActionRegistry__UnsafeCooldown();
        }

        UserConfig storage userConfig = _userConfig[msg.sender];

        // If a user is decreasing their cooldown, lock cooldown
        // will automatically apply, delaying when transferability and plugin
        // approval can be re-enabled, preventing a malicious party from
        // tracking a user to decrease their cooldown to 0 and then enabling
        // transferability.
        if (userConfig.lockCooldown > cooldown) {
            uint40 newCooldown = uint40(
                userConfig.lockCooldown + block.timestamp
            );
            userConfig.transferEnabledTimestamp = newCooldown;
            userConfig.delegationEnabledTimestamp = newCooldown;
        }

        userConfig.lockCooldown = uint208(cooldown);
        emit CooldownSet(msg.sender, cooldown);
    }

    /// TRANSFER MANAGEMENT ///

    /// @notice Checks whether `user` has transferability enabled or disabled
    ///         for their tokens.
    /// @return Returns true if the user has transferability disabled.
    function checkTransfersDisabled(
        address user
    ) external view returns (bool) {
        UserConfig memory userConfig = _userConfig[user];
        return (userConfig.transferDisabled ||
            userConfig.transferEnabledTimestamp > block.timestamp);
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
        UserConfig storage userConfig = _userConfig[msg.sender];

        // Validates that user is intending on flipping their transfer
        // lock status, even though we could assume they want to flip
        // by calling this function, it helps to validate for human error.
        if (transferDisabled == userConfig.transferDisabled) {
            // revert with ActionRegistry__InvalidParams()
            _revert(0x51b33a31);
        }

        uint256 enableTimestamp;

        // If the user is trying to enable transferability again,
        // add their cooldown period, an added layer against phishing
        // attempts.
        if (!transferDisabled) {
            enableTimestamp = _calculateActionEnableTimestamp(
                userConfig.transferEnabledTimestamp
            );
            userConfig.transferEnabledTimestamp = uint40(enableTimestamp);
        }

        userConfig.transferDisabled = transferDisabled;

        // Timestamp emitted is 0 if locking transferability.
        emit LockStatusChanged(msg.sender, transferDisabled, enableTimestamp);
    }

    /// DELEGATION PLUGIN MANAGEMENT ///

    /// @notice Returns `user`'s approval index.
    /// @dev The approval index is a way to revoke approval on all tokens,
    ///      and features at once if a malicious delegation was allowed by
    ///      `user`.
    /// @param user The user to check delegated approval index for.
    /// @return `User`'s approval index.
    function getUserApprovalIndex(
        address user
    ) external view returns (uint256) {
        return _userConfig[user].approvalIndex;
    }

    /// @notice Increments a caller's approval index.
    /// @dev By incrementing their approval index, a user's delegates will all
    ///      have their delegation authority revoked across all Curvance
    ///      contracts.
    ///      Emits an {ApprovalIndexIncremented} event.
    function incrementApprovalIndex() external {
        UserConfig storage userConfig = _userConfig[msg.sender];
        uint256 newIndex = userConfig.approvalIndex + 1;
        userConfig.approvalIndex = uint208(newIndex);

        emit ApprovalIndexIncremented(msg.sender, newIndex);
    }

    /// @notice Checks whether `user` has delegation enabled or disabled
    ///         for user actions inside Curvance.
    /// @return Returns true if the user has delegation disabled.
    function checkDelegationDisabled(
        address user
    ) external view returns (bool) {
        UserConfig memory userConfig = _userConfig[user];
        return (userConfig.delegationDisabled ||
            userConfig.delegationEnabledTimestamp > block.timestamp);
    }

    /// @notice Sets a callers status for whether to allow new delegation
    ///         or not.
    /// @param delegationDisabled Whether caller wants to allow new delegation
    ///                           or not.
    ///      Emits a {DelegableStatusChanged} event.
    function setDelegable(bool delegationDisabled) external {
        UserConfig storage userConfig = _userConfig[msg.sender];

        // Validates that user is intending on flipping their delegation
        // status, even though we could assume they want to flip
        // by calling this function, it helps to validate for human error.
        if (delegationDisabled == userConfig.delegationDisabled) {
            // revert with ActionRegistry__InvalidParams()
            _revert(0x51b33a31);
        }

        uint256 enableTimestamp;

        // If the user is trying to enable delegation again,
        // add their cooldown period, an added layer against phishing
        // attempts.
        if (!delegationDisabled) {
            enableTimestamp = _calculateActionEnableTimestamp(
                userConfig.delegationEnabledTimestamp
            );
            userConfig.delegationEnabledTimestamp = uint40(enableTimestamp);
        }

        userConfig.delegationDisabled = delegationDisabled;

        emit DelegableStatusChanged(
            msg.sender,
            delegationDisabled,
            enableTimestamp
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Checks that action timestamp was not recently updated and
    ///      calculates the timestamp that the desired action will be
    ///      enabled.
    function _calculateActionEnableTimestamp(
        uint256 enabledTimestamp
    ) internal view returns (uint256) {
        // Validate the user did not recently reduce their action cooldown
        // period, triggering their action cooldown.
        if (enabledTimestamp > block.timestamp) {
            // revert with ActionRegistry__InvalidParams()
            _revert(0x51b33a31);
        }

        return (_userConfig[msg.sender].lockCooldown + block.timestamp);
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}
