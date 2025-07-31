// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PricingResult } from "contracts/interfaces/IOracleAdaptor.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";

contract ChainlinkAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for Chainlink price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param aggregator The current phase's aggregator address.
    /// @param decimals Returns the number of decimals the aggregator
    ///                 responds with.
    /// @param heartbeat The max amount of time allowed between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    /// @param reportedMax The maximum valid price of the asset.
    ///                    Set to aggregator maxAnswer() reduced by ~10%.
    /// @param reportedMin The minimum valid price of the asset.
    ///                    Set to aggregator minAnswer() increased by ~10%.
    /// @param max
    /// @param min 
    struct AssetConfig {
        bool isConfigured;
        IChainlink aggregator;
        uint256 decimals;
        uint256 heartbeat;
        uint256 reportedMax;
        uint256 reportedMin;
        uint256 max;
        uint256 min;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for a Chainlink asset heartbeat,
    ///         this value is used instead.
    /// @dev    1 days = 24 hours = 1,440 minutes = 86,400 seconds.
    uint256 public constant DEFAULT_HEART_BEAT = 1 days;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error ChainlinkAdaptor__InvalidHeartbeat();
    error ChainlinkAdaptor__InvalidMinMaxConfig();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of central registry.
    constructor(
        ICentralRegistry centralRegistry_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) BaseOracleAdaptor(
        centralRegistry_,
        MAXIMUM_INCREASE_PER_YEAR,
        MINIMUM_INCREASE_PER_YEAR,
        MAXIMUM_TIMESTAMP_BUFFER,
        MINIMUM_TIMESTAMP_BUFFER
    ) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset` via a new Chainlink feed.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param aggregator Chainlink aggregator to use for pricing `asset`.
    /// @param heartbeat Chainlink heartbeat to use when validating prices
    ///                  for `asset`. 0 = `DEFAULT_HEART_BEAT`.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    function addAsset(
        address asset,
        address aggregator,
        uint256 heartbeat,
        bool inUSD
    ) external {
        _checkElevatedPermissions();

        if (heartbeat != 0) {
            if (heartbeat > DEFAULT_HEART_BEAT) {
                revert ChainlinkAdaptor__InvalidHeartbeat();
            }
        }

        // Use Chainlink to get the min and max of the asset.
        IChainlink feedAggregator = IChainlink(
            IChainlink(aggregator).aggregator()
        );

        // Query Max and Min feed prices from Chainlink aggregator.
        uint256 maxFromChainlink = uint256(
            uint192(feedAggregator.maxAnswer())
        );
        uint256 minFromChainklink = uint256(
            uint192(feedAggregator.minAnswer())
        );

        // Add a ~10% buffer to minimum and maximum price from Chainlink
        // because Chainlink can stop updating its price before/above
        // the min/max price.
        uint256 bufferedMaxPrice = (maxFromChainlink * 9) / 10;
        uint256 bufferedMinPrice = (minFromChainklink * 11) / 10;

        if (bufferedMinPrice >= bufferedMaxPrice) {
            revert ChainlinkAdaptor__InvalidMinMaxConfig();
        }

        AssetConfig storage config = assetConfig[asset][inUSD];

        // Save adaptor data and update mapping that we support `asset` now.
        config.decimals = feedAggregator.decimals();
        config.reportedMax = bufferedMaxPrice;
        config.reportedMin = bufferedMinPrice;
        config.max = type(uint240).max;
        // Data.min is intended to be 0 which is uint256 default value
        // so can skip setting here.
        
        config.heartbeat = heartbeat != 0 ? heartbeat : DEFAULT_HEART_BEAT;
        config.aggregator = IChainlink(aggregator);
        config.isConfigured = true;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, config, isUpdate);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 3;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
    /// @dev Calls latestRoundData() from Chainlink to get the latest data
    ///      for pricing and staleness.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Whether `asset` should be priced in USD or native tokens.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function _getPrice(
        address asset,
        bool inUSD
    ) internal view override returns (PricingResult memory result) {
        // Parse data from the format you want if its configured, otherwise
        // price in the other format and manually convert in Oracle Manager.
        if (!assetConfig[asset][inUSD].isConfigured) {
            inUSD = !inUSD;  
        }

        AssetConfig memory config = assetConfig[asset][inUSD];
        result.inUSD = inUSD;
        
        (, int256 price,, uint256 updatedAt, ) = IChainlink(config.aggregator)
            .latestRoundData();

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price <= 0) {
            result.hadError = true;
            return result;
        }

        if (
            uint256(price) >= config.reportedMax ||
            uint256(price) <= config.reportedMin
            ) {
            result.hadError = true;
            return result;
        }

        uint256 adjustedPrice = _adjustPrice(
            asset,
            inUSD,
            uint256(price),
            config.decimals
        );

        result.hadError = _verifyData(
            adjustedPrice,
            updatedAt,
            config.max,
            config.min,
            config.heartbeat
        );

        result.price = uint240(adjustedPrice);
    }

    /// @notice Wipes supported asset pricing configs from an adaptor.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}