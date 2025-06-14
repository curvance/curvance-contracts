// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IActionRegistry {
    /// @notice Checks whether `user` has transferability enabled or disabled
    ///         for their tokens.
    /// @return Returns true if the user has transferability disabled.
    function checkTransfersDisabled(
        address user
    ) external view returns (bool);

    /// @notice Checks whether `user` has delegation enabled or disabled
    ///         for user actions inside Curvance.
    /// @return Returns true if the user has delegation disabled.
    function checkDelegationDisabled(
        address user
    ) external view returns (bool);

    /// @notice Returns `user`'s approval index.
    /// @dev The approval index is a way to revoke approval on all tokens,
    ///      and features at once if a malicious delegation was allowed by
    ///      `user`.
    /// @param user The user to check delegated approval index for.
    /// @return `User`'s approval index.
    function getUserApprovalIndex(
        address user
    ) external view returns (uint256);
}
