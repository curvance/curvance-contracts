// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Multicall } from "contracts/libraries/Multicall.sol";

import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";

struct AccountSnapshot {
    address asset;
    uint8 decimals;
    bool isCollateral;
    uint256 exchangeRate;
    uint256 collateralPosted;
    uint256 debtBalance;
}

interface ICToken {
    /// @notice Starts a cToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @param by The account initializing deposits.
    function initializeDeposits(address by) external returns (bool);

    /// @notice Returns the decimals of the cToken.
    /// @dev We pull directly from underlying incase its a proxy contract,
    ///      and changes decimals on us.
    /// @return The number of decimals for this cToken,
    ///         matching the underlying token.
    function decimals() external view returns (uint8);

    /// @notice Returns whether the underlying token can be borrowed.
    /// @dev true = Borrowable; false = Not Borrowable.
    /// @return Whether this token is borrowable or not.
    function isBorrowable() external view returns (bool);

    /// @notice The token balance of an account.
    /// @dev Account address => account token balance.
    /// @param account The address of the account to query token balance for.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Returns the address of the underlying asset.
    /// @return The address of the underlying asset.
    function asset() external view returns (address);

    /// @notice Get a snapshot of `account` data in this Curvance token.
    /// @dev Used by marketManager to more efficiently perform
    ///      liquidity checks.
    ///      NOTE: Does not accrue pending interest as part of the call.
    /// @param account The address of the account to snapshot.
    /// @return The account snapshot of `account`.
    function getSnapshot(
        address account
    ) external view returns (AccountSnapshot memory);

    /// @notice Total number of cTokens in circulation.
    function totalSupply() external view returns (uint256);

    /// @notice Returns the total amount of assets held by the market.
    /// @return The total amount of assets held by the market.
    function totalAssets() external view returns (uint256);

    /// @notice Address of the Market Manager linked to this contract.
    function marketManager() external view returns (IMarketManager);

    /// @notice Returns the amount of assets that would be exchanged
    ///         by the vault for `shares` provided.
    /// @param shares The number of shares to theoretically use
    ///               for conversion to assets.
    /// @return The number of assets a user would receive for converting
    ///         `shares`.
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Returns share -> asset exchange rate, in `WAD`.
    /// @dev Oracle Manager calculates cToken value from this exchange rate.
    function exchangeRate() external view returns (uint256);

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        Multicall.MulticallAction[] memory calls
    ) external returns (bytes[] memory results);

    /// @notice Caller deposits `assets` into the market and `receiver`
    ///         receives shares.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits `assets` into the market, `receiver` receives
    ///         shares, and collateralization of `assets` is enabled.
    /// @dev The caller must be depositing for themselves, or be managing
    ///      their position through a Position Manager contract.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function depositAsCollateral(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits `assets` into the market, `receiver` receives
    ///         shares, and collateralization of `assets` is enabled.
    /// @dev Requires that `receiver` approves the caller prior to
    ///      collateralize on their behalf.
    ///      NOTE: Be careful who you approve here!
    ///      They can delay redemption of assets through repeated
    ///      collateralization preventing withdrawal.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function depositAsCollateralFor(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Redeems cTokens to the caller.
    /// @param assets The amount of assets to redeem.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return shares The amount of shares redeemed by `owner`.
    function redeem(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    /// @notice Withdraws assets, quoted in `shares` from the market,
    ///         and burns `owner` shares, sending assets to `receiver`.
    /// @dev Does not force collateral to be withdrawn.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner` and sent to
    ///                `receiver`.
    function redeemFor(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Caller withdraws assets from the market and burns their
    ///         shares, on behalf of `owner`.
    /// @dev Forces collateral to be withdrawn from `owner` collateralPosted.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner` and sent to
    ///                `receiver`.
    function redeemCollateralFor(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Used by a Position Manager contract to redeem assets from
    ///         collateralized shares by `account` to perform a complex
    ///         action.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param owner The owner address of assets to redeem.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function withdrawByPositionManager(
        uint256 assets,
        address owner,
        IPositionManager.DeleverageAction memory action
    ) external;

    /// @notice Amount of tokens that has been posted as collateral,
    ///         in shares.
    function marketCollateralPosted() external view returns (uint256);

    /// @notice Shares of this token that an account has posted as collateral.
    /// @param account The address of the account to check collateral posted
    ///                of.
    function collateralPosted(address account) external view returns (uint256);

    /// @notice Transfers tokens from `account` to `liquidator`.
    /// @dev Will fail unless called by a cToken during the process
    ///      of liquidation.
    /// @param shares An array containing the number of cToken shares
    ///               to seize.
    /// @param liquidator The account receiving seized cTokens.
    /// @param accounts An array containing the accounts having
    ///                 collateral seized.
    function seize(
        uint256[] calldata shares,
        address liquidator,
        address[] calldata accounts
    ) external;

    /// @notice Allows users to simulate the effects of their deposit at
    ///         the current block.
    /// @param assets The number of assets to preview a deposit call.
    /// @return The shares received for depositing `assets`.
    function previewDeposit(uint256 assets) external view returns (uint256);
}
