// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IInterestRateModel } from "contracts/interfaces/IInterestRateModel.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";

interface IBorrowableCToken is ICToken {
    /// @notice Address of the current Interest Rate Model.
    function interestRateModel() external view returns (IInterestRateModel);

    /// @notice Fee that goes to protocol for interested generated for
    ///         lenders, in `WAD`.
    function interestFee() external view returns (uint256);

    /// @notice Can accrue interest yield, configure next interest accrual
    ///         period, and updates vesting data, if needed.
    /// @dev May emit a {InterestAccrualUpdate} event.
    function accrueIfNeeded() external;

    /// @notice The amount of tokens that has been borrowed as debt,
    ///         in assets.
    function marketOutstandingDebt() external view returns (uint256);

    /// @notice Returns the current debt balance for `account`.
    /// @dev Note: Pending interest is not applied in this calculation.
    /// @param account The address whose debt balance should be calculated.
    /// @return result The current outstanding debt balance of `account`.
    function debtBalance(
        address account
    ) external view returns (uint256);

    /// @notice Updates pending interest and returns the up-to-date exchange
    ///         rate from the underlying to the BorrowableCToken.
    /// @return result The share -> asset exchange rate, in `WAD`.
    function exchangeRateUpdated() external returns (uint256);

    /// @notice Used by a delegated user to borrow underlying tokens
    ///         from lenders, based on collateral posted inside this market
    ///         by `account`.
    /// @dev Updates pending interest before executing the borrow.
    ///      NOTE: Be careful who you approve here!
    ///      Not only can they take borrowed funds, but, they can delay
    ///      repayment through repeated borrows preventing withdrawal.
    /// @param account The account who will have their assets borrowed
    ///                against.
    /// @param recipient The account who will receive the borrowed assets.
    /// @param amount The amount of the underlying asset to borrow.
    function borrowFor(
        address account,
        address recipient,
        uint256 amount
    ) external;

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

    /// @notice Gets balance of this contract, in terms of the underlying.
    /// @dev This excludes changes in underlying token balance by the
    ///      current transaction, if any.
    /// @return The quantity of underlying tokens held by the market.
    function assetsHeld() external view returns (uint256);
}