// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseOracleAdaptor, CommonLib, ICentralRegistry } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";
import { HEARTBEAT_GRACE_PERIOD } from "contracts/libraries/ConstantsLib.sol";

import { IRedstone } from "contracts/interfaces/external/redstone/IRedstone.sol";

contract RedstoneClassicAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for Redstone classic price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param feed The Redstone price feed proxy address.
    /// @param decimals Returns the number of decimals `feed` responds with.
    /// @param heartbeat The max amount of time allowed between price updates.
    ///                  0 defaults to using `DEFAULT_HEARTBEAT`.
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
    uint256 public constant DEFAULT_HEARTBEAT =
        1 days + HEARTBEAT_GRACE_PERIOD;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// @notice The current deviation value for an asset's configured price
    ///         feed, in `BPS`.
    /// @dev Token address => inUSD  => feed deviation threshold, in `BPS`.
    mapping(address => mapping(bool => uint256)) internal _assetDeviationThreshold;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error RedstoneClassicAdaptor__InvalidHeartbeat();
    error RedstoneClassicAdaptor__InvalidDeviationThreshold();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    constructor(ICentralRegistry cr) BaseOracleAdaptor(cr, "RedstoneClassicAdaptor") {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset` via a new Redstone feed.
    /// @dev Should be called before `OracleManager:addAssetPricingAdaptor`
    ///      is called.
    ///      NOTE: BE VERY CAREFUL SETTING `feedDeviationThreshold`, AN
    ///            INCORRECT VALUE CAN LOCK LIQUIDATIONS UNINTENTIONALLY.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    /// @param feedProxy Redstone price feed proxy to use for pricing `asset`.
    /// @param heartbeat Redstone heartbeat to use when validating prices
    ///                  for `asset`. 0 = `DEFAULT_HEARTBEAT`.
    /// @param id The dataFeedId of the token to add pricing for,
    ///           in string form.
    /// @param feedDeviationThreshold The price feed deviation threshold value
    ///                               configured by the oracle provider.
    function addAsset(
        address asset,
        bool inUSD,
        address feedProxy,
        uint256 heartbeat,
        string memory id,
        uint256 feedDeviationThreshold
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
            revert RedstoneClassicAdaptor__InvalidHeartbeat();
        }

        // Validate the deviation threshold is not too long.
        if (feedDeviationThreshold > MAX_ALLOWED_DEVIATION_VALUE) {
            revert RedstoneClassicAdaptor__InvalidDeviationThreshold();
        }

        if (Bytes32Helper.toBytes32(id) != IRedstone(feedProxy).getDataFeedId()) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        AssetConfig storage c = assetConfig[asset][inUSD];

        // Update `assetConfig` and make sure `isSupportedAsset` returns true
        // for `asset`.
        c.feedProxy = IRedstone(feedProxy);
        c.decimals = IRedstone(feedProxy).decimals();
        c.heartbeat = uint24(heartbeat != 0 ? heartbeat : DEFAULT_HEARTBEAT);
        c.isConfigured = true;
        _assetDeviationThreshold[asset][inUSD] = feedDeviationThreshold;
        CommonLib._oracleManager(centralRegistry)
            .notifyDeviationUpdated(asset, inUSD, feedDeviationThreshold);

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, c, isUpdate);
    }

    /// @notice Returns an asset's price feed deviation threshold.
    /// @param asset The asset to return the price feed deviation threshold
    ///              for.
    /// @param inUSD Whether the price feed deviation threshold is in
    ///              USD (inUSD = true) or native token (inUSD = false).
    /// @return result The asset's price feed deviation threshold value.
    function deviationThreshold(
        address asset,
        bool inUSD
    ) external view returns (uint256 result) {
        result = _assetDeviationThreshold[asset][inUSD];
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
        result.price = adjustedPrice;
    }

    /// @notice Wipes `asset` pricing configurations from this adaptor.
    /// @param asset The address of the asset to wipe pricing support of.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}