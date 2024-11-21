// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IGaugeManager {
    /// @notice Claim all pending rewards for `token` from the Gauge Manager.
    /// @param tokens Array containing pool token addresses to claim
    ///               rewards for.
    /// @param user The user address that gauge rewards should be claimed for,
    ///             is the user is not the caller, delegation will be checked
    ///             instead.
    function claim(address[] calldata tokens, address user) external;

    /// @notice Returns current epoch number.
    function currentEpoch() external view returns (uint256);

    /// @notice Returns the active reward tokens on the Gauge Manager,
    ///         for ease of integration by third parties.
    function getRewardTokens(address) external view returns (address[] memory);

    /// @notice Sets emission rates of tokens of next epoch.
    /// @dev Only the messaging hub can call this.
    /// @param epoch The epoch to set emission rates for, should be the next epoch.
    /// @param tokens Array containing all tokens to set emission rates for.
    /// @param poolWeights Gauge/Pool weights corresponding to DAO
    ///                    voted emission rates.
    function setEmissionRates(
        uint256 epoch,
        address[] memory tokens,
        uint256[] memory poolWeights
    ) external;

    /// @notice Used to update Gauge Manager rewards for `rewardToken`,
    ///         during `epoch` with `newRewardPerSec`.
    /// @dev This is only be used for updating partner gauge rewards.
    /// @param token The token to set rewards for.
    /// @param epoch The epoch to set rewards for, should be the next epoch.
    /// @param rewardToken The address of reward token to be updated.
    /// @param additionalRewards The additional rewards amount for distribution
    function addExtraRewards(
        address token,
        uint256 epoch,
        address rewardToken,
        uint256 additionalRewards
    ) external;

    /// @notice Deposit into Gauge Manager.
    /// @param token Pool token address.
    /// @param user User address.
    /// @param amount Amounts to deposit.
    function deposit(address token, address user, uint256 amount) external;

    /// @notice Registers a withdrawal of `token` deposits by `user`
    ///         from the Gauge Manager.
    /// @dev This does not actually include any token transfers as tokens
    ///      are permissionlessly escrowed by PToken/EToken contracts and
    ///      we simply record deposits/withdraws here.
    /// @param token Pool token address.
    /// @param user The user address.
    /// @param amount Amounts to withdraw.
    function withdraw(address token, address user, uint256 amount) external;
}
