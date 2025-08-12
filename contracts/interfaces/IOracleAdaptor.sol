// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IOracleAdaptor {
    /// TYPES ///

    /// @notice Return data from pricing an asset.
    /// @param price The price of the asset.
    /// @param inUsd Boolean indicating whether `price` is denominated
    ///              in USD (true) or native token (false).
    /// @param hadError Boolean indicating whether the asset was priced
    ///                 without running into any issues or not.
    struct PricingResult {
        uint240 price;
        bool inUSD;
        bool hadError;
    }

    /// @notice Guard logic when pricing `asset` configured to prevent oracle
    ///         mispricing either by mistake or malicious PriceGuard when
    ///         pricing `asset` denominated either USD or native tokens.
    /// @param guardType The type of PriceGuard to set on `asset`. 
    ///                  Where:
    ///                  1: Indicates a static maximum of `basePrice` and
    ///                     minimum of `minPrice`.
    ///                  2: Indicates an ever increasing maximum of
    ///                     `basePrice` and minimum of `minPrice` continually
    ///                     growing by `increasePerSecond` % per second.
    /// @param ips The magnitude that `basePrice` should increase overtime
    ///            from `timestampStart`, in `WAD`, per second.
    /// @param timestampStart When `increasePerYear` should start increasing
    ///                       `basePrice` raising the maximum price returned
    ///                       when pricing `asset`.
    /// @param minPrice The minimum price that should be allowed to be
    ///                 returned when pricing `asset`.
    /// @param basePrice The base price that should be the maximum price
    ///                  returned when pricing `asset`.
    struct PriceGuard {
        uint40 timestampStart;
        uint40 ips;
        uint80 minPrice;
        uint96 basePrice;
    }

    /// @notice Called by OracleManager to price an asset.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD A boolean to determine if the price should be returned in
    ///              USD or not.
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view returns (PricingResult memory);

    /// @notice Whether an asset is supported by the Oracle Adaptor or not.
    /// @dev Asset => Supported by adaptor.
    function isSupportedAsset(address asset) external view returns (bool);

    /// @notice Token price guard configuration for pricing an asset.
    /// @dev Token address => inUSD => Price Guard configuration.
    function getPriceGuard(
        address asset,
        bool inUSD
    ) external view returns (PriceGuard memory);

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    function adaptorType() external view returns (uint256);
}
