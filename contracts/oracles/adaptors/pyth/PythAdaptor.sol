// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";

import { WAD } from "contracts/libraries/Constants.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { IPyth } from "contracts/interfaces/external/pyth/IPyth.sol";
import { PythStructs } from "contracts/interfaces/external/pyth/PythStructs.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";

contract PythAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for Pyth price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param priceId The price id of the asset to price.
    /// @param heartbeat The max amount of time between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    /// @param max The maximum valid price of the asset.
    ///            0 defaults to use proxy max price reduced by ~10%.
    /// @param min The minimum valid price of the asset.
    ///            0 defaults to use proxy min price increased by ~10%.
    struct AssetConfig {
        bool isConfigured;
        bytes32 priceId;
        uint256 heartbeat;
        uint256 max;
        uint256 min;
    }

    /// CONSTANTS ///

    /// @notice If zero is specified for a Pyth asset heartbeat,
    ///         this value is used instead.
    /// @dev    1 days = 24 hours = 1,440 minutes = 86,400 seconds.
    uint256 public constant DEFAULT_HEART_BEAT = 1 days;

    /// STORAGE ///

    address public nativeUniversalBalance;
    address public pyth;
    address public wrappedNative;

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event PythAssetAdded(
        address asset,
        AssetConfig assetConfig,
        bool isUpdate
    );
    event PythAssetRemoved(address asset);

    /// ERRORS ///

    error PythAdaptor__Unauthorized();
    error PythAdaptor__AssetIsNotSupported();
    error PythAdaptor__InvalidHeartbeat();
    error PythAdaptor__InvalidMinMaxConfig();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of central registry.
    constructor(
        ICentralRegistry centralRegistry_,
        address nativeUniversalBalance_,
        address pyth_,
        address wrappedNative_,
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
    ) {
        nativeUniversalBalance = nativeUniversalBalance_;
        pyth = pyth_;
        wrappedNative = wrappedNative_;
    }

    receive() external payable {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset` via a new Pyth feed.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    /// @param data The adaptor data
    function addAsset(
        address asset,
        bool inUSD,
        AssetConfig memory data
    ) external {
        _checkElevatedPermissions();

        if (data.heartbeat != 0) {
            if (data.heartbeat > DEFAULT_HEART_BEAT) {
                revert PythAdaptor__InvalidHeartbeat();
            }
        }

        // If the buffered max price is above uint240 its theoretically
        // possible to get a price which would lose precision on uint240
        // conversion, which we need to protect against in getPrice() so
        // we can add a second protective layer here.
        if (data.max > type(uint240).max) {
            data.max = type(uint240).max;
        }

        if (data.min >= data.max) {
            revert PythAdaptor__InvalidMinMaxConfig();
        }

        data.isConfigured = true;
        AssetConfig storage config = assetConfig[asset][inUSD];

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit PythAssetAdded(asset, data, isUpdate);
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
            revert PythAdaptor__AssetIsNotSupported();
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
        emit PythAssetRemoved(asset);
    }

    /// @notice Retrieves the price of a given asset.
    /// @dev Uses Pyth oracles to fetch the price data.
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
            revert PythAdaptor__AssetIsNotSupported();
        }

        result = _getPrice(asset, inUSD);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 2;
    }

    function updateFeedsFromUniversalBalance(
        bytes[] calldata priceUpdateData,
        address user
    ) public {
        if (!centralRegistry.isMulticallProvider(msg.sender)) {
            revert PythAdaptor__Unauthorized();
        }
        
        // Update the prices to the latest available values and pay the
        // required fee for it. The `priceUpdateData` data should be retrieved
        // from our off-chain Price Service API using the `pyth-evm-js`
        // package. See section "How Pyth Works on EVM Chains" below for more
        // information.
        uint fee = IPyth(pyth).getUpdateFee(priceUpdateData);

        // Receive oracle update fee from universal balance contract.
        NativeUniversalBalance(payable(nativeUniversalBalance)).useBalanceForOracleUpdate(
            user,
            fee
        );

        uint256 balanceBefore = address(this).balance;
        IWETH(wrappedNative).withdraw(fee);
        IPyth(pyth).updatePriceFeeds{ value: fee }(priceUpdateData);

        // Refund remaining native token paid.
        uint256 remaining = address(this).balance - balanceBefore;
        if (remaining > 0) {
            SafeTransferLib.safeTransferETH(user, remaining);
        }
    }

    function updateFeedsWithNative(
        bytes[] calldata priceUpdateData
    ) public payable {
        // Update the prices to the latest available values and pay the required fee for it. The `priceUpdateData` data
        // should be retrieved from our off-chain Price Service API using the `pyth-evm-js` package.
        // See section "How Pyth Works on EVM Chains" below for more information.
        uint fee = IPyth(pyth).getUpdateFee(priceUpdateData);
        IPyth(pyth).updatePriceFeeds{ value: fee }(priceUpdateData);

        // Refund remaining native token paid.
        uint256 remaining = msg.value - fee;
        if (remaining > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, remaining);
        }
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

    /// @notice Parses the pyth feed data for pricing of an asset.
    /// @dev Calls latestRoundData() from Pyth to get the latest data
    ///      for pricing and staleness.
    /// @param data Pyth feed details.
    /// @param inUSD A boolean to denote if the price is in USD.
    /// @return pData A structure containing the price, error status,
    ///               and the currency of the price.
    function _parseData(
        address asset,
        bool inUSD,
        AssetConfig memory data
    ) internal view returns (PriceReturnData memory pData) {
        pData.inUSD = inUSD;

        PythStructs.Price memory price = IPyth(pyth).getPriceUnsafe(
            data.priceId
        );

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price.price <= 0) {
            pData.hadError = true;
            return pData;
        }

        uint256 normalizedPrice = _normalizePrice(
            asset,
            inUSD,
            uint256(int256(price.price)),
            uint256(int256(-1 * int8(price.expo)))
        );

        pData.hadError = _verifyData(
            normalizedPrice,
            price.publishTime,
            data.max,
            data.min,
            data.heartbeat
        );

        pData.price = uint240(normalizedPrice);
    }
}
