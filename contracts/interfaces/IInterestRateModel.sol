// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IInterestRateModel {
    /// @notice Returns the interval at which interest accrual is calculated.
    /// @notice The interval at which interest accrual is calculated,
    ///         in seconds.
    function accrualPeriod() external view returns (uint256);

    /// @notice The borrowable token linked to this interest rate model
    ///         contract.
    function linkedToken() external view returns (address);

    /// @notice Calculates the current borrow rate per second,
    ///         and updates the vertex multiplier if necessary.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param outstandingDebt The amount of outstanding debt in the pool.
    /// @return borrowRate The borrow rate percentage per second, in `WAD`.
    function getBorrowRateWithUpdate(
        uint256 assetsHeld,
        uint256 outstandingDebt
    ) external returns (uint256);

    /// @notice Calculates the current borrow rate per year,
    ///         with updated vertex multiplier applied.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param outstandingDebt The amount of outstanding debt in the pool.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getPredictedBorrowRatePerYear(
        uint256 assetsHeld,
        uint256 outstandingDebt
    ) external view returns (uint256);
    
    /// @notice Calculates the current borrow rate per year.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param outstandingDebt The amount of outstanding debt in the pool.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getBorrowRatePerYear(
        uint256 assetsHeld,
        uint256 outstandingDebt
    ) external view returns (uint256);

    /// @notice Calculates the current supply rate per year.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param outstandingDebt The amount of outstanding debt in the pool.
    /// @param interestFee The current interest accrual fee for the market.
    /// @return The supply rate percentage per year, in `WAD`.
    function getSupplyRatePerYear(
        uint256 assetsHeld,
        uint256 outstandingDebt,
        uint256 interestFee
    ) external view returns (uint256);

    /// @notice Calculates the borrow utilization rate of the market.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param outstandingDebt The amount of outstanding debt in the pool.
    /// @return The utilization rate between [0, WAD].
    function utilizationRate(
        uint256 assetsHeld,
        uint256 outstandingDebt
    ) external view returns (uint256);
}
