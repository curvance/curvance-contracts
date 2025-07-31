// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
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
    /// @param max The maximum valid price of the asset.
    ///            0 defaults to use proxy max price reduced by ~10%.
    /// @param min The minimum valid price of the asset.
    ///            0 defaults to use proxy min price increased by ~10%.
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

    event ChainlinkAssetAdded(
        address asset,
        AssetConfig assetConfig,
        bool isUpdate
    );
    event ChainlinkAssetRemoved(address asset);

    /// ERRORS ///

    error ChainlinkAdaptor__AssetIsNotSupported();
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

    /// @notice Retrieves the price of a given asset.
    /// @dev Uses Chainlink oracles to fetch the price data.
    ///      Price is returned in USD or a chain's native token depending on
    ///      'inUSD' parameter.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
    /// @return result A struct containing the price, error status,
    ///                and the quote format of the price.
    function getPrice(
        address asset,
        bool inUSD,
        bool /* getLower */
    ) external view override returns (PriceReturnData memory result) {
        // Validate we support pricing `asset`.
        if (!isSupportedAsset[asset]) {
            revert ChainlinkAdaptor__AssetIsNotSupported();
        }

        result = _getPrice(asset, inUSD);
    }

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
        emit ChainlinkAssetAdded(asset, config, isUpdate);
    }

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function removeAsset(address asset) external override {
        _checkElevatedPermissions();

        // Validate that `asset` is currently supported.
        if (!isSupportedAsset[asset]) {
            revert ChainlinkAdaptor__AssetIsNotSupported();
        }

        // Notify the adaptor to stop supporting the asset.
        delete isSupportedAsset[asset];

        // Wipe config mapping entries for a gas refund.
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];

        // Notify the Oracle Manager that we are going to stop supporting
        // the asset.
        IOracleManager(centralRegistry.oracleManager()).notifyFeedRemoval(
            asset
        );
        emit ChainlinkAssetRemoved(asset);
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
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Whether `asset` should be priced in USD or native tokens.
    /// @return result A struct containing the price, error status, and the
    ///                quote format of the price (USD vs native).
    function _getPrice(
        address asset,
        bool inUSD
    ) internal view returns (PriceReturnData memory result) {
        // Parse data from the format you want if its configured, otherwise
        // price in the other format and manually convert in Oracle Manager.
        if (!assetConfig[asset][inUSD].isConfigured) {
            inUSD = !inUSD;  
        }

        result = _parseData(asset, inUSD, assetConfig[asset][inUSD]);
    }

    /// @notice Parses the chainlink feed data for pricing of an asset.
    /// @dev Calls latestRoundData() from Chainlink to get the latest data
    ///      for pricing and staleness.
    /// @param config Chainlink feed details.
    /// @param inUSD A boolean to denote if the price is in USD.
    /// @return pData A structure containing the price, error status,
    ///               and the currency of the price.
    function _parseData(
        address asset,
        bool inUSD,
        AssetConfig memory config
    ) internal view returns (PriceReturnData memory pData) {
        pData.inUSD = inUSD;
        
        (, int256 price, , uint256 updatedAt, ) = IChainlink(config.aggregator)
            .latestRoundData();

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price <= 0) {
            pData.hadError = true;
            return pData;
        }

        if (
            uint256(price) >= config.reportedMax ||
            uint256(price) <= config.reportedMin
            ) {
            pData.hadError = true;
            return pData;
        }

        uint256 normalizedPrice = _normalizePrice(
            asset,
            inUSD,
            uint256(price),
            config.decimals
        );

        pData.hadError = _verifyData(
            normalizedPrice,
            updatedAt,
            config.max,
            config.min,
            config.heartbeat
        );

        pData.price = uint240(normalizedPrice);
    }
}
