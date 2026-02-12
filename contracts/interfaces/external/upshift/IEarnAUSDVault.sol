// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IVault } from "contracts/interfaces/IVault.sol";

interface IEarnAUSDVault is IVault {
    /// @notice The address of the LP token.
    function lpTokenAddress() external returns (address);

    /// @notice Deposits a given amount of input tokens in the vault.
    /// @param assetIn The input token. Reverts if the token is not whitelisted.
    /// @param amountIn The deposit amount.
    /// @param receiverAddr The address that will receive the shares.
    /// @return shares Returns the number of shares
    function deposit(
        address assetIn,
        uint256 amountIn,
        address receiverAddr
    ) external returns (uint256 shares);
}
