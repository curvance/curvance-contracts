// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";
import { HEARTBEAT_GRACE_PERIOD } from "contracts/libraries/ConstantsLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IRedstone } from "contracts/interfaces/external/redstone/IRedstone.sol";

contract RedstoneClassicAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for Redstone classic price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param feed The Redstone price feed proxy address.
    /// @param decimals Returns the number of decimals `feed` responds with.
    /// @param heartbeat The max amount of time allowed between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    struct AssetConfig {
        bool isConfigured;
        IRedstone feedProxy;
        uint8 decimals;
        uint24 heartbeat;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for a Redstone asset heartbeat,
    ///         this value is used instead, added 60 seconds incase of
    ///         transaction congestion delaying an update.
    /// @dev    1 days = 24 hours = 1,440 minutes = 86,400 seconds.
    uint256 public constant DEFAULT_HEART_BEAT = 1 days + HEARTBEAT_GRACE_PERIOD;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error RedstoneClassicAdaptor__InvalidHeartbeat();

    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    constructor(ICentralRegistry cr) BaseOracleAdaptor(cr) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset` via a new Redstone feed.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    /// @param feedProxy Redstone price feed proxy to use for pricing `asset`.
    /// @param heartbeat Redstone heartbeat to use when validating prices
    ///                  for `asset`. 0 = `DEFAULT_HEART_BEAT`.
    /// @param id The dataFeedId of the token to add pricing for.
    function addAsset(
        address asset,
        bool inUSD,
        address feedProxy,
        uint256 heartbeat,
        string memory id
    ) external {
        _checkElevatedPermissions();

        if (heartbeat != 0) {
            if (heartbeat > DEFAULT_HEART_BEAT) {
                revert RedstoneClassicAdaptor__InvalidHeartbeat();
            }
        }

        if (Bytes32Helper.toBytes32(id) != IRedstone(feedProxy).getDataFeedId()) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        AssetConfig storage c = assetConfig[asset][inUSD];

        // Update `assetConfig` and make sure `isSupportedAsset` returns true
        // for `asset`.
        c.feedProxy = IRedstone(feedProxy);
        c.decimals = IRedstone(feedProxy).decimals();
        c.heartbeat = uint24(heartbeat != 0 ? heartbeat : DEFAULT_HEART_BEAT);
        c.isConfigured = true;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, c, isUpdate);
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
    /// @dev Calls latestRoundData() from Redstone to get the latest data
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
        
        (, int256 price,, uint256 updatedAt, ) = IRedstone(c.feedProxy)
            .latestRoundData();

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price <= 0) {
            result.hadError = true;
            return result;
        }

        uint256 adjustedPrice = _adjustPrice(
            asset,
            inUSD,
            uint256(price),
            c.decimals
        );

        result.hadError = _verifyData(adjustedPrice, updatedAt, c.heartbeat);
        result.price = uint240(adjustedPrice);
    }

    /// @notice Wipes `asset` pricing configurations from this adaptor.
    /// @param asset The address of the asset to wipe pricing support of.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}