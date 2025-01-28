// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IMToken } from "./IMToken.sol";
import { IPositionManagement } from "./IPositionManagement.sol";

interface IPToken is IMToken {
    /// @notice Caller deposits assets into the market and receives shares.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits assets into the market, `receiver` receives
    ///         shares, and turns on collateralization of the assets.
    /// @dev The caller must be depositing for themselves, or be managing
    ///      their position through the position folding contract.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function depositAsCollateral(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits assets into the market, `receivier` receives
    ///         shares, and turns on collateralization of the assets.
    /// @dev Requires that `receiver` approves the caller prior to
    ///      collateralize on their behalf.
    ///      NOTE: Be careful who you approve here!
    ///      They can delay redemption of assets through repeated
    ///      collateralization preventing withdrawal.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the pToken shares.
    /// @return shares The amount of pToken shares received by `receiver`.
    function depositAsCollateralFor(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller withdraws assets from the market and burns their shares,
    ///         on behalf of `owner`.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw assets.
    /// @return assets the amount of assets redeemed by `owner`.
    function redeemFor(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Caller withdraws assets from the market and burns their shares,
    ///         on behalf of `owner`.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw assets.
    /// @return assets the amount of assets redeemed by `owner`.
    function redeemCollateralFor(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Helper function for Position Management contract to
    ///         redeem assets.
    /// @param owner The owner address of assets to redeem.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param deleverageData The data for the deleverage operation.
    function withdrawByPositionManagement(
        address owner,
        uint256 assets,
        IPositionManagement.DeleverageStruct memory deleverageData
    ) external;

    /// @notice Transfers collateral tokens (this pToken) from `account`
    ///         to `liquidator`.
    /// @dev Will fail unless called by an eToken during the process
    ///      of liquidation.
    /// @param liquidator The account receiving seized collateral.
    /// @param account The account having collateral seized.
    /// @param liquidatedTokens The total number of pTokens to seize.
    function seize(
        address liquidator,
        address account,
        uint256 liquidatedTokens
    ) external;

    /// @notice Transfers collateral tokens (this market) to the liquidator.
    /// @dev Will fail unless called by the MarketManager itself during
    ///      the process of liquidation.
    ///      NOTE: The protocol never takes a fee on account liquidation
    ///            as lenders already are bearing a burden.
    /// @param liquidator The account receiving seized collateral.
    /// @param account The account having collateral seized.
    /// @param shares The total number of pTokens shares to seize.
    function seizeAccountLiquidation(
        address liquidator,
        address account,
        uint256 shares
    ) external;

    /// @notice Allows users to simulate the effects of their deposit at
    ///         the current block.
    /// @param assets The number of assets to preview a deposit call.
    /// @return The shares received for depositing `assets`.
    function previewDeposit(uint256 assets) external view returns (uint256);
}
