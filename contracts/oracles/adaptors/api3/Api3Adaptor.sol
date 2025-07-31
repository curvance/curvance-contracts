// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { PricingResult } from "contracts/interfaces/IOracleAdaptor.sol";
import { IProxy } from "contracts/interfaces/external/api3/IProxy.sol";

contract Api3Adaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for API3 price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param proxyFeed The current proxy's feed address.
    /// @param dapiNameHash The bytes32 encoded name hash of the price feed.
    /// @param heartbeat The max amount of time between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    /// @param max The max valid price of the asset.
    ///            0 defaults to use proxy max price reduced by ~10%.
    struct AssetConfig {
        bool isConfigured;
        IProxy proxyFeed;
        bytes32 dapiNameHash;
        uint256 heartbeat;
        uint256 max;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for an Api3 asset heartbeat,
    ///         this value is used instead.
    uint256 public constant DEFAULT_HEART_BEAT = 1 days;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event Api3AssetAdded(
        address asset,
        AssetConfig assetConfig,
        bool isUpdate
    );
    event Api3AssetRemoved(address asset);

    /// ERRORS ///

    error Api3Adaptor__DAPINameHashError();
    error Api3Adaptor__InvalidHeartbeat();

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

    /// @notice Adds an Api3 Price Feed as an asset inside this adaptor.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param ticker The ticker of the token to add pricing for.
    /// @param proxyFeed Api3 proxy feed to use for pricing `asset`.
    /// @param heartbeat Api3 heartbeat to use when validating prices
    ///                  for `asset`. 0 = `DEFAULT_HEART_BEAT`.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    function addAsset(
        address asset,
        string memory ticker,
        address proxyFeed,
        uint256 heartbeat,
        bool inUSD
    ) external {
        _checkElevatedPermissions();

        if (heartbeat != 0) {
            if (heartbeat > DEFAULT_HEART_BEAT) {
                revert Api3Adaptor__InvalidHeartbeat();
            }
        }

        bytes32 dapiName = Bytes32Helper.stringToBytes32(ticker);
        bytes32 dapiNameHash = keccak256(abi.encodePacked(dapiName));

        // Validate that the dAPI name and corresponding hash generated off
        // the symbol and denomation match the proxyFeed documented form.
        if (dapiNameHash != IProxy(proxyFeed).dapiNameHash()) {
            revert Api3Adaptor__DAPINameHashError();
        }

        AssetConfig storage config = assetConfig[asset][inUSD];
        config.heartbeat = heartbeat != 0 ? heartbeat : DEFAULT_HEART_BEAT;

        // Save adaptor data and update mapping that we support `asset` now.

        // Add a ~10% buffer to maximum price allowed from Api3 can stop
        // updating its price before/above the min/max price. We use a maximum
        // buffered price of 2^224 - 1, which could overflow when trying to
        // save the final value into an uint240.
        config.max = (uint256(int256(type(int224).max)) * 9) / 10;
        config.dapiNameHash = dapiNameHash;
        config.proxyFeed = IProxy(proxyFeed);
        config.isConfigured = true;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit Api3AssetAdded(asset, config, isUpdate);
    }

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function removeAsset(address asset) external override {
        _checkElevatedPermissions();
        _checkSupportedAsset(asset);

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

        emit Api3AssetRemoved(asset);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    function adaptorType() external pure override returns (uint256) {
        return 4;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
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

        result = _parseData(asset, inUSD, assetConfig[asset][inUSD]);
    }

    /// @notice Parses the Api3 feed data for pricing of an asset.
    /// @dev Calls read() from Api3 to get the latest data
    ///      for pricing and staleness.
    /// @param config Api3 feed details.
    /// @param inUSD A boolean to denote if the price is in USD.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function _parseData(
        address, /* asset */
        bool inUSD,
        AssetConfig memory config
    ) internal view returns (PricingResult memory result) {
        result.inUSD = inUSD;
        
        (int256 price, uint256 updatedAt) = config.proxyFeed.read();

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price <= 0) {
            result.hadError = true;
            return result;
        }

        result.hadError = _verifyData(
            uint256(price),
            updatedAt,
            config.max,
            0,
            config.heartbeat
        );

        result.price = uint240(uint256(price));
    }
}
