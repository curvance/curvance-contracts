// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { IManagementOracle } from "contracts/interfaces/external/chainsight/IManagementOracle.sol";

contract ChainsightAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @title Chainsight Adaptor Data
    /// @notice Stores configuration data for Chainsight price sources.
    /// @param sender The sender address corresponding to `asset`'s feed
    ///               inside Management Oracle.
    /// @param feedKey The ICP VRF randomized key for the asset feed.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param decimals Returns the number of decimals the Feed Key
    ///                 responds with.
    /// @param heartbeat The max amount of time between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    /// @param max The max valid price of the asset.
    ///            0 defaults to use uint224 max price reduced by ~10%.
    struct AdaptorData {
        address sender;
        bytes32 feedKey;
        bool isConfigured;
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

    /// @notice Adaptor configuration data for pricing an asset.
    /// @dev Chainsight Adaptor Data for pricing in gas token.
    mapping(address => AdaptorData) public adaptorDataNonUSD;

    /// @notice Adaptor configuration data for pricing an asset.
    /// @dev Chainsight Adaptor Data for pricing in USD.
    mapping(address => AdaptorData) public adaptorDataUSD;

    /// EVENTS ///

    event ChainsightAssetAdded(
        address asset,
        AdaptorData assetConfig,
        bool isUpdate
    );
    event ChainsightAssetRemoved(address asset);

    /// ERRORS ///

    error ChainsightAdaptor__AssetIsNotSupported();
    error ChainsightAdaptor__InvalidPriceConfiguration();
    error ChainsightAdaptor__InvalidHeartbeat();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of central registry.
    /// @param managementOracle_ The proxy address location for
    ///                          Chainsight oracles on this chain.
    constructor(
        ICentralRegistry centralRegistry_,
        address managementOracle_
    ) BaseOracleAdaptor(centralRegistry_) {
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

    /// @notice Retrieves the price of a given asset.
    /// @dev Uses Chainsight oracles to fetch the price data.
    ///      Price is returned in USD or a chain's native token depending on
    ///      'inUSD' parameter.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Specifies whether the price format should be in
    ///              USD (true) or a chain's native token (false).
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price.
    function getPrice(
        address asset,
        bool inUSD,
        bool /* getLower */
    ) external view override returns (PriceReturnData memory) {
        // Validate we support pricing `asset`.
        if (!isSupportedAsset[asset]) {
            revert ChainsightAdaptor__AssetIsNotSupported();
        }

        if (inUSD) {
            return _getPriceInUSD(asset);
        }

        return _getPriceInNative(asset);
    }

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

        AdaptorData storage data;
        if (inUSD) {
            data = adaptorDataUSD[asset];
        } else {
            data = adaptorDataNonUSD[asset];
        }

        data.heartbeat = heartbeat != 0 ? heartbeat : DEFAULT_HEART_BEAT;

        if (block.timestamp - readTimestampSigned > heartbeat) {
            revert ChainsightAdaptor__InvalidPriceConfiguration();
        }

        // Save adaptor data and update mapping that we support `asset` now.

        // Add a ~10% buffer to maximum price allowed from Chainsight can stop
        // updating its price before/above the min/max price. We use a maximum
        // buffered price of 2^240 - 1, which could overflow when trying to
        // save the final value into an uint240.
        data.max = (uint256(int256(type(int240).max)) * 9) / 10;
        data.sender = sender;
        data.feedKey = feedKey;
        data.decimals = decimals;
        data.isConfigured = true;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit ChainsightAssetAdded(asset, data, isUpdate);
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
            revert ChainsightAdaptor__AssetIsNotSupported();
        }

        // Notify the adaptor to stop supporting the asset.
        delete isSupportedAsset[asset];

        // Wipe config mapping entries for a gas refund.
        delete adaptorDataUSD[asset];
        delete adaptorDataNonUSD[asset];

        // Notify the Oracle Manager that we are going to stop supporting
        // the asset.
        IOracleManager(centralRegistry.oracleManager()).notifyFeedRemoval(
            asset
        );

        emit ChainsightAssetRemoved(asset);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 16;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given asset in USD.
    /// @param asset The address of the asset for which the price is needed.
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price (USD).
    function _getPriceInUSD(
        address asset
    ) internal view returns (PriceReturnData memory) {
        if (adaptorDataUSD[asset].isConfigured) {
            return _parseData(adaptorDataUSD[asset], true);
        }

        return _parseData(adaptorDataNonUSD[asset], false);
    }

    /// @notice Retrieves the price of a given asset in the chain's native
    ///         gas token.
    /// @param asset The address of the asset for which the price is needed.
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price (native).
    function _getPriceInNative(
        address asset
    ) internal view returns (PriceReturnData memory) {
        if (adaptorDataNonUSD[asset].isConfigured) {
            return _parseData(adaptorDataNonUSD[asset], false);
        }

        return _parseData(adaptorDataUSD[asset], true);
    }

    /// @notice Parses the Chainsight feed data for pricing of an asset.
    /// @dev Calls read() from Chainsight to get the latest data
    ///      for pricing and staleness.
    /// @param data Chainsight feed details.
    /// @param inUSD A boolean to denote if the price is in USD.
    /// @return pData A structure containing the price, error status,
    ///               and the currency of the price.
    function _parseData(
        AdaptorData memory data,
        bool inUSD
    ) internal view returns (PriceReturnData memory pData) {
        (
            int256 price,
            uint256 updatedAt
        ) = MANAGEMENT_ORACLE.readAsInt256WithTimestamp(
            data.sender,
            data.feedKey
        );

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price <= 0) {
            pData.hadError = true;
            return pData;
        }

        uint256 newPrice = (uint256(price) * WAD) / (10 ** data.decimals);

        pData.price = uint240(newPrice);
        pData.hadError = _verifyData(
            uint256(price),
            updatedAt,
            data.max,
            0,
            data.heartbeat
        );
        pData.inUSD = inUSD;
    }
}
