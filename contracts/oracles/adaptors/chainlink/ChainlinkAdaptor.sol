// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseOracleAdaptor, CommonLib, ICentralRegistry } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { HEARTBEAT_GRACE_PERIOD } from "contracts/libraries/ConstantsLib.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";

contract ChainlinkAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for Chainlink price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param aggregatorProxy Chainlink aggregator proxy to use for
    ///                        pricing `asset`.
    /// @param decimals Returns the number of decimals the proxy denominates
    ///                 asset prices in.
    /// @param heartbeat The max amount of time allowed between price updates.
    ///                  0 defaults to using `DEFAULT_HEARTBEAT`.
    struct AssetConfig {
        bool isConfigured;
        IChainlink aggregatorProxy;
        uint8 decimals;
        uint24 heartbeat;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for a Chainlink asset heartbeat,
    ///         this value is used instead.
    /// @dev    1 days = 24 hours = 1,440 minutes = 86,400 seconds.
    uint256 public constant DEFAULT_HEARTBEAT =
        1 days + HEARTBEAT_GRACE_PERIOD;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error ChainlinkAdaptor__InvalidHeartbeat();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    constructor(ICentralRegistry cr) BaseOracleAdaptor(cr, "ChainlinkAdaptor") {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset` via a new Chainlink feed.
    /// @dev Should be called before `OracleManager:addAssetPricingAdaptor`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    /// @param aggregatorProxy Chainlink aggregator proxy to use for
    ///                        pricing `asset`.
    /// @param heartbeat Chainlink heartbeat to use when validating prices
    ///                  for `asset`. 0 = `DEFAULT_HEARTBEAT`.
    function addAsset(
        address asset,
        bool inUSD,
        address aggregatorProxy,
        uint256 heartbeat
    ) external {
        _checkElevatedPermissions();

        // If we are not using the default heartbeat directly, apply
        // `HEARTBEAT_GRACE_PERIOD` to `heartbeat` to make sure it,
        // was not missed.
        if (heartbeat != 0) {
            heartbeat = heartbeat + HEARTBEAT_GRACE_PERIOD;
        }

        // Validate the feed heartbeat is not too long.
        if (heartbeat > DEFAULT_HEARTBEAT) {
            revert ChainlinkAdaptor__InvalidHeartbeat();
        }

        AssetConfig storage config = assetConfig[asset][inUSD];

        // Update `config` and make sure `isSupportedAsset` returns true
        // for `asset`.
        config.aggregatorProxy = IChainlink(aggregatorProxy);
        config.decimals = IChainlink(aggregatorProxy).decimals();
        config.heartbeat = uint24(heartbeat != 0 ? heartbeat : DEFAULT_HEARTBEAT);
        config.isConfigured = true;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, config, isUpdate);
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

        AssetConfig memory c = assetConfig[asset][inUSD];
        result.inUSD = inUSD;
        
        (, int256 price,, uint256 updatedAt, ) = IChainlink(c.aggregatorProxy)
            .latestRoundData();

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price <= 0) {
            result.hadError = true;
            return result;
        }

        // Adjust price pulled, if necessary.
        uint256 adjustedPrice =
            _adjustPrice(asset, inUSD, uint256(price), c.decimals);

        result.hadError = _verifyData(adjustedPrice, updatedAt, c.heartbeat);
        result.price = adjustedPrice;
    }

    /// @notice Wipes `asset` pricing configurations from this adaptor.
    /// @param asset The address of the asset to wipe pricing support of.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}