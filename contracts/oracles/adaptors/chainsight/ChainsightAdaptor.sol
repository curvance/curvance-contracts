// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IManagementOracle } from "contracts/interfaces/external/chainsight/IManagementOracle.sol";

contract ChainsightAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for Chainsight price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param sender The sender address corresponding to `asset`'s feed
    ///               inside Management Oracle.
    /// @param feedKey The ICP VRF randomized key for the asset feed.
    /// @param decimals Returns the number of decimals the Feed Key
    ///                 responds with.
    /// @param heartbeat The max amount of time between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    /// @param max The max valid price of the asset.
    ///            0 defaults to use uint224 max price reduced by ~10%.
    struct AssetConfig {
        bool isConfigured;
        address sender;
        bytes32 feedKey;
        uint256 decimals;
        uint256 heartbeat;
        uint256 max;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for a Chainsight asset heartbeat,
    ///         this value is used instead.
    uint256 public constant DEFAULT_HEART_BEAT = 1 days;

    IManagementOracle public immutable MANAGEMENT_ORACLE;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error ChainsightAdaptor__InvalidPriceConfiguration();
    error ChainsightAdaptor__InvalidHeartbeat();

    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    /// @param managementOracle_ The proxy address location for
    ///                          Chainsight's oracles on this chain.
    constructor(
        ICentralRegistry cr,
        address managementOracle_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) BaseOracleAdaptor(
        cr,
        MAXIMUM_INCREASE_PER_YEAR,
        MINIMUM_INCREASE_PER_YEAR,
        MAXIMUM_TIMESTAMP_BUFFER,
        MINIMUM_TIMESTAMP_BUFFER
    ) {
        IManagementOracle(managementOracle_).readAsUint256WithTimestamp(
            address(0),
            bytes32(0)
        );
        IManagementOracle(managementOracle_).readAsInt256WithTimestamp(
            address(0),
            bytes32(0)
        );

        MANAGEMENT_ORACLE = IManagementOracle(managementOracle_);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds a Chainsight Price Feed as an asset inside this adaptor.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param sender The sender address corresponding to `asset`'s feed
    ///               inside Management Oracle.
    /// @param feedKey The ICP VRF randomized key for the asset feed.
    /// @param decimals Returns the number of decimals the Feed Key
    ///                 responds with.
    /// @param heartbeat Chainsight heartbeat to use when validating prices
    ///                  for `asset`. 0 = `DEFAULT_HEART_BEAT`.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    function addAsset(
        address asset,
        address sender,
        bytes32 feedKey,
        uint256 decimals,
        uint256 heartbeat,
        bool inUSD
    ) external {
        _checkElevatedPermissions();

        if (heartbeat != 0) {
            if (heartbeat > DEFAULT_HEART_BEAT) {
                revert ChainsightAdaptor__InvalidHeartbeat();
            }
        }

        // Validate that the Chainsight sender and feedKey from frontend
        // properly return data as expected.
        (
            uint256 readPriceUnsigned,
        ) = MANAGEMENT_ORACLE.readAsUint256WithTimestamp(sender, feedKey);

        (
            int256 readPriceSigned,
            uint256 readTimestampSigned
        ) = MANAGEMENT_ORACLE.readAsInt256WithTimestamp(sender, feedKey);

        if (uint256(readPriceSigned) != readPriceUnsigned) {
            revert ChainsightAdaptor__InvalidPriceConfiguration();
        }

        if (readPriceSigned <= 0) {
            revert ChainsightAdaptor__InvalidPriceConfiguration();
        }

        AssetConfig storage config = assetConfig[asset][inUSD];

        config.heartbeat = heartbeat != 0 ? heartbeat : DEFAULT_HEART_BEAT;

        if (block.timestamp - readTimestampSigned > heartbeat) {
            revert ChainsightAdaptor__InvalidPriceConfiguration();
        }

        // Save adaptor data and update mapping that we support `asset` now.

        // Add a ~10% buffer to maximum price allowed from Chainsight can stop
        // updating its price before/above the min/max price. We use a maximum
        // buffered price of 2^240 - 1, which could overflow when trying to
        // save the final value into an uint240.
        config.max = (uint256(int256(type(int240).max)) * 9) / 10;
        config.sender = sender;
        config.feedKey = feedKey;
        config.decimals = decimals;
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
        return 16;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
    /// @dev Calls read() from Chainsight to get the latest data
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
        
        (
            int256 price,
            uint256 updatedAt
        ) = MANAGEMENT_ORACLE.readAsInt256WithTimestamp(
            config.sender,
            config.feedKey
        );

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price <= 0) {
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
            0,
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