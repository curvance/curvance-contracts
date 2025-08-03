// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IDiaOracle } from "contracts/interfaces/external/dia/IDiaOracle.sol";

contract DIAAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for DIA price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param decimals Returns the number of decimals the aggregator
    ///                 responds with.
    /// @param max The maximum valid price of the asset.
    ///            0 defaults to use proxy max price reduced by ~10%.
    /// @param min The minimum valid price of the asset.
    ///            0 defaults to use proxy min price increased by ~10%.
    /// @param heartbeat The max amount of time between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    struct AssetConfig {
        bool isConfigured;
        uint256 decimals;
        uint256 max;
        uint256 min;
        uint256 heartbeat;
        string key;
    }

    /// STORAGE ///

    address public diaOracle;

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error DIAAdaptor__InvalidHeartbeat();
    error DIAAdaptor__InvalidMinMaxConfig();

    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    constructor(
        ICentralRegistry cr,
        address _diaOracle,
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
        diaOracle = _diaOracle;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset` via a new DIA feed.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param adaptor The adaptor configuration
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    function addAsset(
        address asset,
        AssetConfig memory adaptor,
        bool inUSD
    ) external {
        _checkElevatedPermissions();

        if (adaptor.min >= adaptor.max) {
            revert DIAAdaptor__InvalidMinMaxConfig();
        }

        // Save `config` and update mapping that we support `asset` now.
        assetConfig[asset][inUSD] = adaptor;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, adaptor, isUpdate);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 6;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
    /// @dev Calls getValue() from DIA to get the latest data
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

        (uint128 price, uint128 updatedAt) = IDiaOracle(diaOracle).getValue(
            config.key
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