// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

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
    /// @param priceId The price id
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param heartbeat The max amount of time between price updates.
    ///                  0 defaults to using DEFAULT_HEART_BEAT.
    /// @param max The maximum valid price of the asset.
    ///            0 defaults to use proxy max price reduced by ~10%.
    /// @param min The minimum valid price of the asset.
    ///            0 defaults to use proxy min price increased by ~10%.
    struct AdaptorData {
        bytes32 priceId;
        bool isConfigured;
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

    address public universalBalance;
    address public pyth;
    address public weth;

    /// @notice Adaptor configuration data for pricing an asset in gas token.
    /// @dev Pyth Adaptor Data for pricing in gas token.
    mapping(address => AdaptorData) public adaptorDataNonUSD;

    /// @notice Adaptor configuration data for pricing an asset in USD.
    /// @dev Pyth Adaptor Data for pricing in USD.
    mapping(address => AdaptorData) public adaptorDataUSD;

    /// EVENTS ///

    event PythAssetAdded(
        address asset,
        AdaptorData assetConfig,
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
        address universalBalance_,
        address pyth_,
        address weth_
    ) BaseOracleAdaptor(centralRegistry_) {
        universalBalance = universalBalance_;
        pyth = pyth_;
        weth = weth_;
    }

    receive() external payable {}

    /// EXTERNAL FUNCTIONS ///

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
        UniversalBalance(payable(universalBalance)).useBalanceForOracleUpdate(
            user,
            fee
        );

        uint256 balanceBefore = address(this).balance;
        IWETH(weth).withdraw(fee);
        IPyth(pyth).updatePriceFeeds{ value: fee }(priceUpdateData);

        // Refund remaining native token paid.
        uint256 remaining = address(this).balance - balanceBefore;
        if (remaining > 0) {
            SafeTransferLib.safeTransferETH(user, remaining);
        }
    }

    function updateFeedsWithETH(
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

    /// @notice Retrieves the price of a given asset.
    /// @dev Uses Pyth oracles to fetch the price data.
    ///      Price is returned in USD or a chain's native token depending on
    ///      'inUSD' parameter.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price.
    function getPrice(
        address asset,
        bool inUSD,
        bool /* getLower */
    ) external view override returns (PriceReturnData memory) {
        // Validate we support pricing `asset`.
        if (!isSupportedAsset[asset]) {
            revert PythAdaptor__AssetIsNotSupported();
        }

        // Check whether we want the pricing in USD first,
        // otherwise price in terms of the gas token.
        if (inUSD) {
            return _getPriceInUSD(asset);
        }

        return _getPriceInETH(asset);
    }

    /// @notice Adds pricing support for `asset` via a new Pyth feed.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or ETH (inUSD = false).
    /// @param data The adaptor data
    function addAsset(
        address asset,
        bool inUSD,
        AdaptorData memory data
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
        if (inUSD) {
            adaptorDataUSD[asset] = data;
        } else {
            adaptorDataNonUSD[asset] = data;
        }

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
        delete adaptorDataUSD[asset];
        delete adaptorDataNonUSD[asset];

        // Notify the Oracle Manager that we are going to stop supporting
        // the asset.
        IOracleManager(centralRegistry.oracleManager()).notifyFeedRemoval(
            asset
        );
        emit PythAssetRemoved(asset);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    function adaptorType() external pure override returns (uint256) {
        return 2;
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

    /// @notice Retrieves the price of a given asset in ETH.
    /// @param asset The address of the asset for which the price is needed.
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price (ETH).
    function _getPriceInETH(
        address asset
    ) internal view returns (PriceReturnData memory) {
        if (adaptorDataNonUSD[asset].isConfigured) {
            return _parseData(adaptorDataNonUSD[asset], false);
        }

        return _parseData(adaptorDataUSD[asset], true);
    }

    /// @notice Parses the pyth feed data for pricing of an asset.
    /// @dev Calls latestRoundData() from Pyth to get the latest data
    ///      for pricing and staleness.
    /// @param data Pyth feed details.
    /// @param inUSD A boolean to denote if the price is in USD.
    /// @return pData A structure containing the price, error status,
    ///               and the currency of the price.
    function _parseData(
        AdaptorData memory data,
        bool inUSD
    ) internal view returns (PriceReturnData memory pData) {
        pData.inUSD = inUSD;
        if (
            !IOracleManager(centralRegistry.oracleManager()).isSequencerValid()
        ) {
            pData.hadError = true;
            return pData;
        }

        PythStructs.Price memory price = IPyth(pyth).getPriceUnsafe(
            data.priceId
        );

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price.price <= 0) {
            pData.hadError = true;
            return pData;
        }

        uint8 decimals = uint8(-1 * int8(price.expo));
        uint256 newPrice = (uint256(int256(price.price)) * WAD) /
            (10 ** decimals);

        pData.price = uint240(newPrice);
        pData.hadError = _verifyData(
            uint256(int256(price.price)),
            price.publishTime,
            data.max,
            data.min,
            data.heartbeat
        );
    }

    /// @notice Validates the feed data based on various constraints.
    /// @dev Checks if the value is within a specific range
    ///      and if the data is not outdated.
    /// @param value The value that is retrieved from the feed data.
    /// @param timestamp The time at which the value was last updated.
    /// @param max The maximum limit of the value.
    /// @param min The minimum limit of the value.
    /// @param heartbeat The maximum allowed time difference between
    ///                  current time and 'timestamp'.
    /// @return A boolean indicating whether the feed data had an error
    ///         (true = error, false = no error).
    function _verifyData(
        uint256 value,
        uint256 timestamp,
        uint256 max,
        uint256 min,
        uint256 heartbeat
    ) internal view virtual returns (bool) {
        // Validate `value` is not below the buffered min value allowed.
        if (value < min) {
            return true;
        }

        // Validate `value` is not above the buffered maximum value allowed.
        if (value > max) {
            return true;
        }

        // Validate the price returned is not stale.
        if (block.timestamp - timestamp > heartbeat) {
            return true;
        }

        return false;
    }
}
