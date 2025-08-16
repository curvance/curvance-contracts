// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICVE {
    /// @notice Sets allowance of `spender` over the caller's tokens.
    /// @dev Included here so we don't need to recast to IERC20.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Mints gauge emissions for the desired gauge pool.
    /// @dev Only callable by the MessagingHub.
    /// @param gaugeManager The address of the gauge pool where emissions will be
    ///                  configured.
    /// @param amount The amount of gauge emissions to be minted.
    function mintGaugeEmissions(address gaugeManager, uint256 amount) external;

    /// @notice Mints CVE to the calling gauge pool to fund the users
    ///         lock boost.
    /// @param amount The amount of tokens to be minted.
    function mintLockBoost(uint256 amount) external;

    /// @notice Mint CVE to msg.sender,
    ///         which will always be the VeCVE contract.
    /// @dev Only callable by the MessagingHub.
    ///      This function is used only for creating a bridged VeCVE lock.
    /// @param amount The amount of token to mint for the new veCVE lock.
    function mintLockedTokens(address recipient, uint256 amount) external;

    /// @notice Burn CVE from msg.sender,
    ///         which will always be the VeCVE contract.
    /// @dev Only callable by VeCVE.
    ///      This function is used only for bridging VeCVE lock.
    /// @param recipient The address of recipient on destination chain.
    /// @param dstChainId Chain ID of the target blockchain.
    /// @param amount The amount of token to burn for a bridging veCVE lock.
    function burnLockedTokens(
        address recipient,
        uint256 dstChainId,
        uint256 amount
    ) external;

    /// @notice Finalizes bridging of CVE by minting `amount` CVE
    ///         to `recipient`.
    /// @param recipient The address of CVE recipient.
    /// @param amount The amount of token to receive.
    function completeBridge(address recipient, uint256 amount) external;
}
