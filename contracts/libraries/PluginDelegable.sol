// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

/// @title Curvance Plugin Delegation Manager.
/// @notice Facilitates delegated actions on behalf of a user inside Curvance.
/// @dev `PluginDelegable` allows the Curvance Protocol to be a modular system
///      that plugins can be built on top of. By delegating action authority
///      to an address or addresses users can utilize potential third-party
///      features such as limit orders, crosschain actions, reward auto
///      compounding, chained (multiple sequential) actions, etc.
abstract contract PluginDelegable {
    /// STORAGE ///

    /// @notice Curvance DAO Hub.
    ICentralRegistry public immutable centralRegistry;

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
    error PluginDelegable__InvalidCentralRegistry();
    error PluginDelegable__DelegatingDisabled();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert PluginDelegable__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns whether `delegate` has the ability to act on behalf of
    ///         `user`.
    /// @param user The address to check whether `delegate` has delegation
    ///             permissions for.
    /// @param delegate The address to check delegation permissions of `user`.
    /// @return Returns whether `delegate` is an approved delegate of `user`.
    function isDelegate(
        address user,
        address delegate
    ) public view returns (bool) {
        return _isDelegate[user][getUserApprovalIndex(user)][delegate];
    }

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
        if (checkDelegationDisabled(msg.sender)) {
            revert PluginDelegable__DelegatingDisabled();
        }

        uint256 approvalIndex = getUserApprovalIndex(msg.sender);
        _isDelegate[msg.sender][approvalIndex][delegate] = isApproved;

        emit DelegateApproval(msg.sender, delegate, approvalIndex, isApproved);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns `user`'s approval index.
    /// @dev The approval index is a way to revoke approval on all tokens,
    ///      and features at once if a malicious delegation was allowed by
    ///      `user`.
    /// @param user The user to check delegated approval index for.
    /// @return `User`'s approval index.
    function getUserApprovalIndex(address user) public view returns (uint256) {
        return centralRegistry.getUserApprovalIndex(user);
    }

    /// @notice Returns whether a user has delegation disabled.
    /// @dev This is not a silver bullet for phishing attacks, but, adds
    ///      an additional wall of defense.
    /// @param user The user to check delegation status for.
    /// @return Whether the user has new delegation disabled or not.
    function checkDelegationDisabled(address user) public view returns (bool) {
        return centralRegistry.checkDelegationDisabled(user);
    }

    /// @notice Checks whether `delegate` has the ability to act on behalf of
    ///         `user`, reverts if they do not.
    /// @param user The address to check whether `delegate` has delegation
    ///             permissions for.
    /// @param delegate The address to check delegation permissions of `user`.
    function _checkDelegate(
        address user,
        address delegate
    ) internal view {
        if (!_isDelegate[user][
                centralRegistry.getUserApprovalIndex(user)
            ][delegate]) {
            /// @solidity memory-safe-assembly
            assembly {
                mstore(0x00, 0xcfdc5602) // bytes4(keccak256(bytes("PluginDelegable__Unauthorized()")))
                revert(0x1c, 0x04)
            }
        }
    }
}
