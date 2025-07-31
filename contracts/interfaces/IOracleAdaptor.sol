// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// TYPES ///

/// @notice Return data from an Oracle Adaptor.
/// @param price The price of the asset in some asset, either ETH or USD.
/// @param hadError The message return data, whether the adaptor ran into
///                 trouble pricing the asset.
/// @param inUsd Boolean indicating whether the price feed is denominated
///              in USD (true) or ETH (false).
struct PriceReturnData {
    uint240 price;
    bool hadError;
    bool inUSD;
}


struct PriceGuard {
    uint256 guardType;
    uint256 timestampStart;
    uint256 increasePerSecond;
    uint256 basePrice;
    uint256 minPrice;
}

interface IOracleAdaptor {
    /// @notice Called by OracleManager to price an asset.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD A boolean to determine if the price should be returned in
    ///              USD or not.
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view returns (PriceReturnData memory);

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
