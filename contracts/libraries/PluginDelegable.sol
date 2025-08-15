// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";

/// @title Curvance Plugin Delegation Manager.
/// @notice Facilitates delegated actions on behalf of a user inside Curvance.
/// @dev `PluginDelegable` allows the Curvance Protocol to be a modular system
///      that plugins can be built on top of. By delegating action authority
///      to an address or addresses users can utilize potential third-party
///      features such as limit orders, crosschain actions, reward auto
///      compounding, chained (multiple sequential) actions, etc.
abstract contract PluginDelegable is IPluginDelegable {
    /// CONSTANTS ///
    
    /// @notice Curvance DAO Hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Status of whether a user or contract has the ability to act
    ///         on behalf of an account.
    /// @dev Account address => approval index => Spender address => Can act
    ///      on behalf of account.
    mapping(address => mapping(uint256 => mapping(address => bool)))
        internal _isDelegate;

    /// EVENTS ///

    event DelegateApproval(
        address indexed owner,
        address indexed delegate,
        uint256 approvalIndex,
        bool isApproved
    );

    /// ERRORS ///

    error PluginDelegable__Unauthorized();
    error PluginDelegable__DelegatingDisabled();
    error PluginDelegable_InvalidParameter();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Approves or restricts `delegate`'s authority to operate
    ///         on the caller's behalf.
    /// @dev NOTE: Be careful who you approve here!
    ///      They can delay actions such as asset redemption through repeated
    ///      denial of service.
    ///      Emits a {DelegateApproval} event.
    /// @param delegate The address that will be approved or restricted
    ///                 from delegated actions on behalf of the caller.
    /// @param isApproved Whether `delegate` is being approved or restricted
    ///                   of authority to operate on behalf of caller.
    function setDelegateApproval(address delegate, bool isApproved) external {
        if (delegate == msg.sender) {
            revert PluginDelegable_InvalidParameter();
        }

        if (centralRegistry.checkDelegationDisabled(msg.sender)) {
            revert PluginDelegable__DelegatingDisabled();
        }

        uint256 currentIndex = centralRegistry.userApprovalIndex(msg.sender);
        _isDelegate[msg.sender][currentIndex][delegate] = isApproved;

        emit DelegateApproval(msg.sender, delegate, currentIndex, isApproved);
    }

    /// @notice Returns `user`'s current approval index value.
    /// @dev The approval index is a way to revoke approval on all tokens,
    ///      and features at once if a malicious delegation was allowed by
    ///      `user`.
    /// @param user The user to check delegated approval index for.
    /// @return result The `user`'s current approval index value.
    function userApprovalIndex(
        address user
    ) external view returns (uint256 result) {
        result = centralRegistry.userApprovalIndex(user);
    }

    /// @notice Returns whether `delegate` has the ability to act on behalf of
    ///         `user`.
    /// @param user The address to check whether `delegate` has delegation
    ///             permissions for.
    /// @param delegate The address to check delegation permissions of `user`.
    /// @return result Indicates whether `delegate` is an approved delegate or
    ///                not of `user`, true = is a delegate, false = is not
    ///                a delegate.
    function isDelegate(
        address user,
        address delegate
    ) external view returns (bool result) {
        result = _isDelegate[user][centralRegistry
            .userApprovalIndex(user)][delegate];
    }

    /// @notice Returns whether a user has delegation disabled.
    /// @dev This is not a silver bullet for phishing attacks, but, adds
    ///      an additional wall of defense.
    /// @param user The user to check delegation status for.
    /// @return result Indicates whether `user` has delegation disabled
    ///                or not, true = disabled, false = not disabled.
    function checkDelegationDisabled(
        address user
    ) external view returns (bool result) {
        result = centralRegistry.checkDelegationDisabled(user);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Checks whether `delegate` has the ability to act on behalf of
    ///         `user`, reverts if they do not.
    /// @param user The address to check whether `delegate` has delegation
    ///             permissions for.
    /// @param delegate The address to check delegation permissions of `user`.
    function _checkDelegate(address user, address delegate) internal view {
        if (
            !_isDelegate[user][centralRegistry
                .userApprovalIndex(user)][delegate]
        ) {
            revert PluginDelegable__Unauthorized();
        }
    }
}
