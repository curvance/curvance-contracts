// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IPluginDelegable {
    /// @notice Returns whether a user or contract has the ability to act
    ///         on behalf of an account.
    /// @param user The address to check whether `delegate` has delegation
    ///             permissions.
    /// @param delegate The address that will be approved or restricted
    ///                 from delegated actions on behalf of the caller.
    /// @return result Indicates whether `delegate` is an approved delegate or
    ///                not of `user`, true = disabled, false = not disabled.
    function isDelegate(
        address user,
        address delegate
    ) external view returns (bool result);

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
    function setDelegateApproval(address delegate, bool isApproved) external;
}
