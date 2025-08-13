// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";
import { HEARTBEAT_GRACE_PERIOD } from "contracts/libraries/ConstantsLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IProxy } from "contracts/interfaces/external/api3/IProxy.sol";

contract Api3Adaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for API3 price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param proxyFeed The current proxy's feed address.
    /// @param heartbeat The max amount of time allowed between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    /// @param dapiNameHash The bytes32 encoded name hash of the price feed. 
    struct AssetConfig {
        bool isConfigured;
        IProxy proxyFeed;
        uint24 heartbeat;
        bytes32 dapiNameHash;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for an Api3 asset heartbeat,
    ///         this value is used instead.
    uint256 public constant DEFAULT_HEART_BEAT = 1 days + HEARTBEAT_GRACE_PERIOD;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error Api3Adaptor__DAPINameHashError();
    error Api3Adaptor__InvalidHeartbeat();

    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    constructor(ICentralRegistry cr) BaseOracleAdaptor(cr) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds an Api3 Price Feed as an asset inside this adaptor.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    /// @param proxyFeed Api3 proxy feed to use for pricing `asset`.
    /// @param heartbeat Api3 heartbeat to use when validating prices
    ///                  for `asset`. 0 = `DEFAULT_HEART_BEAT`.
    /// @param ticker The ticker of the token to add pricing for.
    function addAsset(
        address asset,
        bool inUSD,
        address proxyFeed,
        uint256 heartbeat,
        string memory ticker
    ) external {
        _checkElevatedPermissions();

        if (heartbeat != 0) {
            if (heartbeat > DEFAULT_HEART_BEAT) {
                revert Api3Adaptor__InvalidHeartbeat();
            }
        }

        bytes32 dapiName = Bytes32Helper.toBytes32(ticker);
        bytes32 dapiNameHash = keccak256(abi.encodePacked(dapiName));

        // Validate that the dAPI name and corresponding hash generated off
        // the symbol and denomation match the proxyFeed documented form.
        if (dapiNameHash != IProxy(proxyFeed).dapiNameHash()) {
            revert Api3Adaptor__DAPINameHashError();
        }

        AssetConfig storage config = assetConfig[asset][inUSD];
        config.heartbeat = uint24(heartbeat != 0 ? heartbeat : DEFAULT_HEART_BEAT);

        // Save `config` and update mapping that we support `asset` now.
        config.dapiNameHash = dapiNameHash;
        config.proxyFeed = IProxy(proxyFeed);
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
    function adaptorType() external pure override returns (uint256) {
        return 5;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
    /// @dev Calls read() from Api3 to get the latest data
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
        
        (int256 price, uint256 updatedAt) = c.proxyFeed.read();

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price <= 0) {
            result.hadError = true;
            return result;
        }

        result.hadError = _verifyData(uint256(price), updatedAt, c.heartbeat);
        result.price = uint240(uint256(price));
    }

    /// @notice Wipes supported asset pricing configs from an adaptor.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}