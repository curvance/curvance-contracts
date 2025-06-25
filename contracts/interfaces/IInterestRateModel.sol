// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IInterestRateModel {
    /// @notice Returns the interval at which interest accrues to
    ///         outstanding debt.
    /// @return The interval at which interest accrues.
    function accrualPeriod() external view returns (uint256);

    /// @notice The borrowable token linked to this interest rate model
    ///         contract.
    function linkedToken() external view returns (address);
    
    /// @notice Calculates the current borrow rate, per compound.
    /// @param assetsHeld The amount of underlying assets currently held
    ///                   on hand.
    /// @param borrows The amount of borrows in the market.
    /// @return The borrow rate percentage, per compound, in `WAD`.
    function getBorrowRate(
        uint256 assetsHeld,
        uint256 borrows
    ) external view returns (uint256);

    /// @notice Calculates the current borrow rate per year.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getBorrowRatePerYear(
        uint256 cash,
        uint256 borrows
    ) external view returns (uint256);

    /// @notice Calculates the current borrow rate per year,
    ///         with updated vertex multiplier applied.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getPredictedBorrowRatePerYear(
        uint256 cash,
        uint256 borrows
    ) external view returns (uint256);

    /// @notice Calculates the current borrow rate per compound,
    ///         and updates the vertex multiplier if necessary.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @return borrowRate The borrow rate percentage per compound, in `WAD`.
    function getBorrowRateWithUpdate(
        uint256 cash,
        uint256 borrows
    ) external returns (uint256);

    /// @notice Calculates the current supply rate per year.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @param interestFee The current interest rate reserve factor
    ///                    for the market.
    /// @return The supply rate percentage per year, in `WAD`.
    function getSupplyRatePerYear(
        uint256 cash,
        uint256 borrows,
        uint256 interestFee
    ) external view returns (uint256);

    /// @notice Calculates the borrow utilization rate of the market.
    /// @param assetsHeld The amount of underlying assets held in the
    ///                       market.
    /// @param outstandingDebt The amount of outstanding debt in the market.
    /// @return result The utilization rate between [0, WAD].
    function utilizationRate(
        uint256 assetsHeld,
        uint256 outstandingDebt
    ) external view returns (uint256 result);
}
