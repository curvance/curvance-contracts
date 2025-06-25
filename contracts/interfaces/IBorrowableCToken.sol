// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IInterestRateModel } from "contracts/interfaces/IInterestRateModel.sol";
import { ICToken } from "./ICToken.sol";
import { IPositionManager } from "./IPositionManager.sol";

interface IBorrowableCToken is ICToken {
    /// @notice Address of the current Interest Rate Model.
    function interestRateModel() external view returns (IInterestRateModel);

    /// @notice Fee that goes to protocol for interested generated for
    ///         lenders, in `WAD`.
    function interestFee() external view returns (uint256);

    /// @notice Applies pending interest to all holders, updating
    ///         `totalBorrows` and `totalReserves`.
    /// @dev This calculates interest accrued from the last checkpoint
    ///      up to the latest available checkpoint, if `compoundRate`
    ///      seconds has passed.
    ///      Emits a {InterestAccrued} event.
    function accrueInterest() external;

    /// @notice The amount of tokens that has been borrowed as debt,
    ///         in assets.
    function marketOutstandingDebt() external view returns (uint256);

    /// @notice Returns total amount borrowed from the market.
    /// @return The total amount of borrowed assets.
    function totalBorrows() external view returns (uint256);

    /// @notice Returns the quantity of underlying tokens held by the market.
    /// @return The quantity of underlying tokens held by the market.
    function marketUnderlyingHeld() external view returns (uint256);

    /// @notice Returns the current debt balance for `account`.
    /// @dev Note: Pending interest is not applied in this calculation.
    /// @param account The address whose balance should be calculated.
    /// @return The current balance index of `account`.
    function debtBalanceCached(
        address account
    ) external view returns (uint256);

    /// @notice Updates pending interest and returns the up-to-date exchange
    ///         rate from the underlying to the eToken.
    /// @return Calculated exchange rate, in `WAD`.
    function exchangeRateWithUpdate() external returns (uint256);

    /// @notice Helper function for Position Manager contract to
    ///         borrow assets.
    /// @param account The account address to borrow on behalf of.
    /// @param amount The amount of the underlying assets to borrow.
    /// @param leverageData The data for the leverage operation.
    function borrowForPositionManager(
        address account,
        uint256 amount,
        IPositionManager.LeverageStruct memory leverageData
    ) external;

    /// @notice Repays underlying tokens to lenders, on behalf of `account`,
    ///         freeing up their collateral posted inside this market.
    /// @dev Updates pending interest before executing the repay.
    /// @param account The account address to repay on behalf of.
    /// @param amount The amount to repay, or 0 for the full outstanding amount.
    function repayFor(address account, uint256 amount) external;

    /// @notice Process withdraw reserves.
    /// @dev This function is called by the CentralRegistry contract to process withdraw reserves.
    ///      It is used to withdraw reserves from the market.
    function processWithdrawReserves() external;

    /// @notice Mints cTokens to the caller.
    /// @param shares The amount of shares to mint.
    /// @param receiver The account that should receive the cToken shares.
    /// @return assets The amount of assets minted.
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Redeems cTokens to the caller.
    /// @param assets The amount of assets to redeem.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return shares The amount of shares redeemed by `owner`.
    function redeem(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Redeems cTokens to the caller.
    /// @param shares The amount of shares to redeem.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner`.
    function redeemFor(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Redeems underlying tokens to the caller.
    /// @param assets The amount of assets to redeem.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return shares The amount of shares redeemed by `owner`.
    function redeemUnderlying(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Redeems underlying tokens to the caller.
    /// @param shares The amount of shares to redeem.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner`.
    function redeemUnderlyingFor(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    
    /// @notice Returns the total amount of assets held by the market.
    /// @return The total amount of assets held by the market.
    function totalAssets() external view returns (uint256);

    /// @notice Returns the total amount of reserves held by the market.
    /// @return The total amount of reserves held by the market.
    function totalReserves() external view returns (uint256);

    /// @notice Returns the interest factor of the market.
    /// @return The interest factor of the market.
    function interestFactor() external view returns (uint256);

    /// @notice Gets balance of this contract, in terms of the underlying.
    /// @dev This excludes changes in underlying token balance by the
    ///      current transaction, if any.
    /// @return The quantity of underlying tokens held by the market.
    function assetsHeld() external view returns (uint256);
    
}