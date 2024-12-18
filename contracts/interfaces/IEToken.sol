// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IInterestRateModel } from "contracts/interfaces/IInterestRateModel.sol";
import { IMToken } from "./IMToken.sol";

interface IEToken is IMToken {
    /// @notice Address of the current Interest Rate Model.
    function interestRateModel() external view returns (IInterestRateModel);

    /// @notice Applies pending interest to all holders, updating
    ///         `totalBorrows` and `totalReserves`.
    /// @dev This calculates interest accrued from the last checkpoint
    ///      up to the latest available checkpoint, if `compoundRate`
    ///      seconds has passed.
    ///      Emits a {InterestAccrued} event.
    function accrueInterest() external;

    /// @notice Updates pending interest and returns the up-to-date exchange
    ///         rate from the underlying to the eToken.
    /// @return Calculated exchange rate, in `WAD`.
    function exchangeRateWithUpdate() external returns (uint256);

    /// @notice Deposits underlying assets into the market,
    ///         and receives eTokens.
    /// @dev Updates pending interest before executing the mint inside
    ///      the internal helper function.
    /// @param amount The amount of the underlying assets to deposit.
    /// @return Returns the amount of eTokens minted.
    function mint(uint256 amount) external returns (uint256);

    /// @notice Deposits underlying assets into the market,
    ///         and `recipient` receives eTokens.
    /// @dev Updates pending interest before executing the mint inside
    ///      the internal helper function.
    /// @param amount The amount of the underlying assets to deposit.
    /// @param recipient The account that should receive the eTokens.
    /// @return tokens Returns the amount of eTokens minted.
    function mintFor(
        uint256 amount,
        address recipient
    ) external returns (uint256);

    /// @notice Redeems eTokens in exchange for the underlying asset.
    /// @dev Updates pending interest before executing the redemption.
    /// @param tokens The number of eTokens to redeem for underlying tokens.
    /// @param recipient The account who will receive the underlying assets.
    /// @return Returns amount of underlying asset redeemed.
    function redeem(
        uint256 tokens,
        address recipient
    ) external returns (uint256);

    /// @notice Used by the market manager contract to repay a portion
    ///         of underlying token debt to lenders, remaining debt shortfall
    ///        is recognized equally by lenders due to `account` default.
    /// @dev Only market manager contract can call this function.
    ///      Updates pending interest prior to execution of the repay,
    ///      inside the market manager contract.
    /// @param liquidator The account liquidating `account`'s collateral,
    ///                   and repaying a portion of `account`'s debt.
    /// @param account The account being liquidated and repaid on behalf of.
    /// @param repayRatio The ratio of outstanding debt that `liquidator`
    ///                   will repay from `account`'s obligations,
    ///                   out of 100%, in `WAD`.
    function repayWithBadDebt(
        address liquidator,
        address account,
        uint256 repayRatio
    ) external;

    /// @notice Withdraws all reserves from the gauge and transfers them to
    ///         Curvance DAO.
    /// @dev If daoAddress is going to be moved all reserves should be
    ///      withdrawn first. Updates pending interest before executing
    ///      the reserve withdrawal.
    function processWithdrawReserves() external;

    /// @notice Returns total amount of outstanding borrows of the
    ///         underlying in this eToken market.
    function totalBorrows() external view returns (uint256);

    /// @notice Returns the current debt balance for `account`.
    /// @dev Note: Pending interest is not applied in this calculation.
    /// @param account The address whose balance should be calculated.
    /// @return The current balance index of `account`.
    function debtBalanceCached(
        address account
    ) external view returns (uint256);

    /// @notice Calculates the current eToken utilization rate.
    /// @dev Used for third party integrations, and frontends.
    /// @return The utilization rate, in `WAD`.
    function utilizationRate() external view returns (uint256);

    /// @notice Returns the current eToken borrow interest rate per year.
    /// @dev Used for third party integrations, and frontends.
    /// @return The borrow interest rate per year, in `WAD`.
    function borrowRatePerYear() external view returns (uint256);

    /// @notice Returns predicted upcoming eToken borrow interest rate
    ///         per year.
    /// @dev Used for third party integrations, and frontends.
    /// @return The predicted borrow interest rate per year, in `WAD`.
    function predictedBorrowRatePerYear() external view returns (uint256);

    /// @notice Returns the current eToken supply interest rate per year.
    /// @dev Used for third party integrations, and frontends.
    /// @return The supply interest rate per year, in `WAD`.
    function supplyRatePerYear() external view returns (uint256);
}
