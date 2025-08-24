// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IActionRegistry {
    /// @notice Checks whether `user` has transferability enabled or disabled
    ///         for their tokens.
    /// @param user The address to check whether transferability is enabled or
    ///             disabled for.
    /// @return result Indicates whether `user` has transferability disabled
    ///                or not, true = disabled, false = not disabled.
    function checkTransfersDisabled(
        address user
    ) external view returns (bool result);

    /// @notice Checks whether `user` has delegation enabled or disabled
    ///         for user actions inside Curvance.
    /// @param user The address to check whether delegation is enabled or
    ///             disabled for.
    /// @return result Indicates whether `user` has delegation disabled
    ///                or not, true = disabled, false = not disabled.
    function checkDelegationDisabled(
        address user
    ) external view returns (bool result);

    /// @notice Returns `user`'s approval index.
    /// @dev The approval index is a way to revoke approval on all tokens,
    ///      and features at once if a malicious delegation was allowed by
    ///      `user`.
    /// @param user The user to check delegated approval index for.
    /// @return result The `user`'s current approval index value.
    function userApprovalIndex(
        address user
    ) external view returns (uint256 result);
}
