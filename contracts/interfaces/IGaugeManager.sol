// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

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

    /// @notice Registers an `amount` withdrawal of `token` for `user` and
    ///         registers an `amount` deposit of `token` for `liquidator`
    ///         inside the Gauge System on a liquidation of `user`.
    /// @dev This does not actually include any token transfers as tokens
    ///      are permissionlessly escrowed by pToken/eToken contracts and
    ///      we simply record deposits/withdraws as virtual balances here.
    /// @param token Protocol supported mToken address to withdraw for
    ///              `user`.
    /// @param user User address to withdraw `amount` of `token` for, on
    ///             liquidation.
    /// @param liquidator User address to deposit `amount` of `token` for, on
    ///                   liquidation.
    /// @param amount The amount of `token` to move from `user` and
    ///               `liquidator` on liquidation.
    function processLiquidation(
        address token,
        address user,
        address liquidator,
        uint256 amount
    ) external;
}
