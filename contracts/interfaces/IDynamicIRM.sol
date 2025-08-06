// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDynamicIRM {
    /// @notice Returns the interval at which interest rates are adjusted.
    /// @notice The interval at which interest rates are adjusted,
    ///         in seconds.
    function ADJUSTMENT_RATE() external view returns (uint256);

    /// @notice The borrowable token linked to this interest rate model
    ///         contract.
    function linkedToken() external view returns (address);

    /// @notice Calculates the current borrow rate, per second.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The borrow interest rate percentage, per second,
    ///                in `WAD`.
    function borrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) external view returns (uint256 result);

    /// @notice Calculates the current borrow rate per second,
    ///         with updated vertex multiplier applied.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The borrow rate percentage per second, in `WAD`.
    function predictedBorrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) external view returns (uint256 result);

    /// @notice Calculates the current supply rate, per second.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @param interestFee The current interest rate protocol fee
    ///                    for the market token.
    /// @return result The supply interest rate percentage, per second,
    ///                in `WAD`.
    function supplyRate(
        uint256 assetsHeld,
        uint256 debt,
        uint256 interestFee
    ) external view returns (uint256 result);

    /// @notice Calculates the interest rate paid per second by borrowers,
    ///         in percentage paid, per second, in `WAD`, and updates
    ///         `vertexMultiplier` if necessary.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return ratePerSecond The interest rate paid per second by borrowers,
    ///                       in percentage paid, per second, in `WAD`.
    /// @return adjustmentRate The period of time at which interest rates are
    ///                        adjusted, in seconds.
    function adjustedBorrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) external returns (uint256 ratePerSecond, uint256 adjustmentRate);

    /// @notice Calculates the borrow utilization rate of the market.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param outstandingDebt The amount of outstanding debt in the pool.
    /// @return The utilization rate between [0, WAD].
    function utilizationRate(
        uint256 assetsHeld,
        uint256 outstandingDebt
    ) external view returns (uint256);
}
