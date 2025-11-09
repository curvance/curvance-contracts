// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseOracleAdaptor, CommonLib, ICentralRegistry } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";

import { HEARTBEAT_GRACE_PERIOD } from "contracts/libraries/ConstantsLib.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";

import { IPyth } from "contracts/interfaces/external/pyth/IPyth.sol";
import { PythStructs } from "contracts/interfaces/external/pyth/PythStructs.sol";

contract PythAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Stores configuration data for Pyth price sources.
    /// @param isConfigured Whether the asset is configured or not.
    ///                     false = unconfigured; true = configured.
    /// @param heartbeat The max amount of time allowed between price updates.
    ///                  type(uint256).max defaults to using
    ///                  `DEFAULT_HEARTBEAT`.
    /// @param priceId The price id of the asset to price.
    struct AssetConfig {
        bool isConfigured;
        uint24 heartbeat;
        bytes32 priceId;
    }

    /// CONSTANTS ///

    /// @notice If type(uint256).max is specified for an asset heartbeat,
    ///         `DEFAULT_HEARTBEAT` is used instead.
    /// @dev    1 days = 24 hours = 1,440 minutes = 86,400 seconds.
    ///         We use type(uint256).max instead of 0 for trigger as we may
    ///         want 0 second requirement on redstone pull oracles.
    uint256 public constant DEFAULT_HEARTBEAT =
        1 days + HEARTBEAT_GRACE_PERIOD;

    /// @notice The address of the Native Universal Balance contract linked
    ///         to the Pyth Adaptor.
    address public immutable nativeUniversalBalance;
    /// @notice The address of the Pyth oracle hub on this chain.
    address public immutable pyth;
    /// @notice The address of wrapped native token on this chain.
    address public immutable wrappedNative;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => inUSD => Price feed configuration for `asset`.
    mapping(address => mapping(bool => AssetConfig)) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error PythAdaptor__InvalidHeartbeat();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param wNative The address of wrapped native token.
    constructor(
        ICentralRegistry cr,
        address nativeUniversalBalance_,
        address pyth_,
        address wNative
    ) BaseOracleAdaptor(cr, "PythAdaptor") {
        nativeUniversalBalance = nativeUniversalBalance_;
        pyth = pyth_;
        wrappedNative = wNative;
    }

    receive() external payable {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset` via a new Pyth feed.
    /// @dev Should be called before `OracleManager:addAssetPricingAdaptor`
    ///      is called.
    ///      NOTE: BE VERY CAREFUL SETTING `feedDeviationThreshold`, AN
    ///            INCORRECT VALUE CAN LOCK LIQUIDATIONS UNINTENTIONALLY.
    /// @param asset The address of the token to add pricing support for.
    /// @param inUSD Whether the price feed is in USD (inUSD = true)
    ///              or native token (inUSD = false).
    /// @param heartbeat The max amount of time allowed between price updates.
    /// @param priceId The price id of the asset to price.
    /// @param feedDeviationThreshold The price feed deviation threshold value
    ///                               configured by the oracle provider.
    function addAsset(
        address asset,
        bool inUSD,
        uint256 heartbeat,
        bytes32 priceId,
        uint256 feedDeviationThreshold
    ) external {
        _checkElevatedPermissions();

        if (heartbeat != type(uint256).max) {
            // Apply `HEARTBEAT_GRACE_PERIOD` to `heartbeat` to make sure it
            // was not missed.
            heartbeat = heartbeat + HEARTBEAT_GRACE_PERIOD;

            // Validate the feed heartbeat is not too long if it is not
            // using the default value.
            if (heartbeat > DEFAULT_HEARTBEAT) {
                revert PythAdaptor__InvalidHeartbeat();
            }
        }

        // Update `config` and make sure `isSupportedAsset` returns true
        // for `asset`.
        AssetConfig storage config = assetConfig[asset][inUSD];

        config.heartbeat = uint24(heartbeat != type(uint256).max ?
            heartbeat : DEFAULT_HEARTBEAT);
        config.priceId = priceId;
        config.isConfigured = true;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, config, isUpdate);
    }

    function updateFeedsFromUniversalBalance(
        bytes[] calldata priceUpdateData,
        address user
    ) public {
        IPluginDelegable(nativeUniversalBalance).isDelegate(user, msg.sender);

        // Update the prices to the latest available values and pay the
        // required fee for it. The `priceUpdateData` data should be retrieved
        // from our off-chain Price Service API using the `pyth-evm-js`
        // package. See section "How Pyth Works on EVM Chains" below for more
        // information.
        uint fee = IPyth(pyth).getUpdateFee(priceUpdateData);

        // Receive oracle update fee from universal balance contract.
        NativeUniversalBalance(payable(nativeUniversalBalance))
            .useBalanceForOracleUpdate(user, fee);

        uint256 balanceBefore = address(this).balance;
        IWETH(wrappedNative).withdraw(fee);
        IPyth(pyth).updatePriceFeeds{ value: fee }(priceUpdateData);

        // Refund remaining native token paid.
        uint256 remaining = address(this).balance - balanceBefore;
        if (remaining > 0) {
            SafeTransferLib.safeTransferETH(user, remaining);
        }
    }

    /// @notice Updates Pyth prices using native gas tokens for the chain.
    /// @dev The `priceUpdateData` data should be retrieved
    /// from Pyth's off-chain Price Service API using the `pyth-evm-js`
    /// package.
    /// @param priceUpdateData The calldata representing a price update.
    function updateFeedsWithNative(
        bytes[] calldata priceUpdateData
    ) public payable {
        // Update the prices to the latest available values and pay the
        // required fee for it. 
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
    /// @dev Calls getPriceUnsafe() from Pyth to get the latest data
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

        PythStructs.Price memory price = IPyth(pyth).getPriceUnsafe(
            config.priceId
        );

        // If we got a price of 0 or less, bubble up an error immediately.
        if (price.price <= 0) {
            result.hadError = true;
            return result;
        }

        // Adjust price pulled, if necessary.
        uint256 adjustedPrice = _adjustPrice(
            asset,
            inUSD,
            uint256(int256(price.price)),
            uint256(int256(-1 * int8(price.expo)))
        );

        result.hadError = _verifyData(
            adjustedPrice,
            price.publishTime,
            config.heartbeat
        );
        result.price = adjustedPrice;
    }

    /// @notice Wipes `asset` pricing configurations from this adaptor.
    /// @param asset The address of the asset to wipe pricing support of.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset][true];
        delete assetConfig[asset][false];
    }
}