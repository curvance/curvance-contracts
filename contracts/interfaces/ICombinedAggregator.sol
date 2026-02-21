// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICombinedAggregator {
    /// @notice Returns the current PriceGuard configuration.
    /// @dev Returns individual fields since Solidity auto-generates getters
    ///      for public struct variables that return fields separately.
    function pg()
        external
        view
        returns (
            uint40 timestampStart,
            uint40 ips,
            uint88 basePrice,
            uint88 minPrice
        );

    /// @notice Sets a PriceGuard when pricing via `secondaryAggregator`.
    /// @param timestampStart When `ips` should start increasing `basePrice`
    ///                       raising the maximum price returned when pricing
    ///                       `asset`.
    /// @param ips The magnitude that `basePrice` should increase overtime
    ///            overtime from `timestampStart`, in `WAD`, in seconds.
    /// @param basePrice The base price that should be the maximum price
    ///                  returned when pricing `asset`.
    /// @param minPrice The minimum price that should be allowed to be
    ///                 returned when pricing `asset`.
    function setGuardedPriceConfig(
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) external;

    /// @notice Disables any active PriceGuard.
    function disableGuardedPriceConfig() external;
}