// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseOracleAdaptor, CommonLib, ICentralRegistry } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { IDiaOracle } from "contracts/interfaces/external/dia/IDiaOracle.sol";

contract DIAAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for DIA price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param decimals Returns the number of decimals the aggregator
    ///                 responds with.
    /// @param heartbeat The max amount of time allowed between price updates.
    ///                  0 defaults to using `DEFAULT_HEARTBEAT`.
    struct AssetConfig {
        bool isConfigured;
        uint256 decimals;
        uint256 heartbeat;
        string key;
    }

    /// STORAGE ///

    address public diaOracle;

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// @notice The current deviation value for an asset's configured price
    ///         feed, in `BPS`.
    /// @dev Token address => feed deviation threshold, in `BPS`.
    mapping(address => uint256) internal _assetDeviationThreshold;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error DIAAdaptor__InvalidHeartbeat();
    error DIAAdaptor__InvalidDeviationThreshold();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param dia The address of the proxy contract containing all dia price
    ///            feeds on this chain.
    constructor(ICentralRegistry cr, address dia) BaseOracleAdaptor(cr, "DIAAdaptor") {
        diaOracle = dia;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset` via a new DIA feed.
    /// @dev Should be called before `OracleManager:addAssetPricingAdaptor`
    ///      is called.
    ///      NOTE: BE VERY CAREFUL SETTING `feedDeviationThreshold`, AN
    ///            INCORRECT VALUE CAN LOCK LIQUIDATIONS UNINTENTIONALLY.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    /// @param config The asset's adaptor configuration.
    /// @param feedDeviationThreshold The price feed deviation threshold value
    ///                               configured by the oracle provider.
    function addAsset(
        address asset,
        bool inUSD,
        AssetConfig memory config,
        uint256 feedDeviationThreshold
    ) external {
        _checkElevatedPermissions();

        // Validate the deviation threshold is not too long.
        if (feedDeviationThreshold > MAX_ALLOWED_DEVIATION_VALUE) {
            revert DIAAdaptor__InvalidDeviationThreshold();
        }

        // Save `config` and update mapping that we support `asset` now.
        assetConfig[asset][inUSD] = config;
        _assetDeviationThreshold[asset] = feedDeviationThreshold;
        CommonLib._oracleManager(centralRegistry)
            .notifyDeviationUpdated(asset, feedDeviationThreshold);

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, config, isUpdate);
    }

    /// @notice Returns an asset's price feed deviation threshold.
    /// @param asset The asset to return the price feed deviation threshold for.
    /// @return result The asset's price feed deviation threshold value.
    function deviationThreshold(
        address asset
    ) external view returns (uint256 result) {
        result = _assetDeviationThreshold[asset];
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
        AssetConfig memory c = assetConfig[asset][inUSD];
        result.inUSD = inUSD;

        (uint128 price, uint128 updatedAt) =
            IDiaOracle(diaOracle).getValue(c.key);

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
        result.price = adjustedPrice;
    }

    /// @notice Wipes `asset` pricing configurations from this adaptor.
    /// @param asset The address of the asset to wipe pricing support of.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}