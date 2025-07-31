// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { PendleLpOracleLib } from "contracts/libraries/external/pendle/PendleLpOracleLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";

import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PricingResult } from "contracts/interfaces/IOracleAdaptor.sol";

contract PendleLPTokenAdaptor is BaseOracleAdaptor {
    using PendleLpOracleLib for IPMarket;

    /// TYPES ///

    /// @notice Stores configuration data for Pendle LP price sources.
    /// @param pt The address of the Pendle PT associated with LP.
    /// @param twapDuration The twap duration to use when pricing.
    /// @param quoteAsset The asset the twap quote is provided in.
    /// @param quoteAssetDecimals The decimals `quoteAsset` twap quote
    ///                           is provided in.
    struct AssetConfig {
        address pt;
        uint32 twapDuration;
        address quoteAsset;
        uint8 quoteAssetDecimals;
    }

    /// CONSTANTS ///

    /// @notice The minimum acceptable twap duration when pricing.
    uint32 public constant MINIMUM_TWAP_DURATION = 12;
    /// @notice Current network's ptOracle.
    /// @dev for mainnet use 0x414d3C8A26157085f286abE3BC6E1bb010733602.
    IPendlePTOracle public immutable ptOracle;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => Price feed configuration for `asset`.
    mapping(address => AssetConfig) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);
    event PendleLPAssetRemoved(address asset);

    /// ERRORS ///

    error PendleLPTokenAdaptor__WrongMarket();
    error PendleLPTokenAdaptor__WrongQuote();
    error PendleLPTokenAdaptor__TwapDurationIsLessThanMinimum();
    error PendleLPTokenAdaptor__QuoteAssetIsNotSupported();
    error PendleLPTokenAdaptor__CallIncreaseCardinality();
    error PendleLPTokenAdaptor__OldestObservationIsNotSatisfied();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of central registry.
    constructor(
        ICentralRegistry centralRegistry_,
        IPendlePTOracle ptOracle_,
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
        ptOracle = ptOracle_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given Pendle lp token.
    /// @dev Price is returned in USD or a chain's native token depending on
    ///      'inUSD' parameter.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view override returns (PricingResult memory result) {
        _checkSupportedAsset(asset);

        AssetConfig memory data = assetConfig[asset];
        // Get LP to underlying asset ratio conversion.
        uint256 lpRate = IPMarket(asset).getLpToAssetRate(data.twapDuration);

        (uint256 price, uint256 errorCode) = IOracleManager(
            centralRegistry.oracleManager()
        ).getPrice(data.quoteAsset, inUSD, getLower);

        // Validate we did not run into any errors pricing the quote asset.
        if (errorCode > 0) {
            result.hadError = true;
            return result;
        }

        // Multiply the quote asset price by the lpRate
        // to get the Lp Token fair value.
        price = (price * lpRate) / WAD;

        // Validate price will not overflow on conversion to uint240.
        if (_checkOverflow(price)) {
            result.hadError = true;
            return result;
        }

        result.inUSD = inUSD;
        result.price = uint240(price);
    }

    /// @notice Adds pricing support for `asset`, a pendle lp token.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the Pendle lp token to add pricing
    ///              support for.
    /// @param data The adaptor data needed to add `asset`.
    function addAsset(address asset, AssetConfig memory data) external {
        _checkElevatedPermissions();

        // Make sure pt and market match.
        (IStandardizedYield sy, IPPrincipalToken pt, ) = IPMarket(asset)
            .readTokens();

        // Validate pt pulled from market matches pt inside `data`.
        if (address(pt) != data.pt) {
            revert PendleLPTokenAdaptor__WrongMarket();
        }

        // Validate the parameter twap duration is within acceptable bounds.
        if (data.twapDuration < MINIMUM_TWAP_DURATION) {
            revert PendleLPTokenAdaptor__TwapDurationIsLessThanMinimum();
        }

        // Make sure quote asset is the same as SY `assetInfo.assetAddress`.
        (, address assetAddress, ) = sy.assetInfo();
        if (assetAddress != data.quoteAsset) {
            revert PendleLPTokenAdaptor__WrongQuote();
        }

        // Make sure the underlying PT TWAP is working.
        _checkPtTwap(asset, data.twapDuration);

        // Validate we support the pricing quote asset for this LP token.
        if (
            !IOracleManager(centralRegistry.oracleManager()).isSupportedAsset(
                data.quoteAsset
            )
        ) {
            revert PendleLPTokenAdaptor__QuoteAssetIsNotSupported();
        }

        // Save adaptor data and update mapping that we support `asset` now.
        assetConfig[asset] = data;

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        isSupportedAsset[asset] = true;
        emit AssetAdded(asset, data, isUpdate);
    }

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function removeAsset(address asset) external override {
        _checkElevatedPermissions();
        _checkSupportedAsset(asset);

        // Wipe config mapping entries for a gas refund.
        // Notify the adaptor to stop supporting the asset.
        delete isSupportedAsset[asset];
        delete assetConfig[asset];

        // Notify the Oracle Manager that we are going to stop supporting
        // the asset.
        IOracleManager(centralRegistry.oracleManager()).notifyFeedRemoval(
            asset
        );
        emit PendleLPAssetRemoved(asset);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 10;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Helper function to check whether the underlying PT TWAP
    ///         is working.
    /// @param market The address of the Pendle LP.
    /// @param twapDuration The twap duration to use when pricing.
    function _checkPtTwap(address market, uint32 twapDuration) internal view {
        (
            bool increaseCardinalityRequired,
            ,
            bool oldestObservationSatisfied
        ) = ptOracle.getOracleState(market, twapDuration);

        if (increaseCardinalityRequired) {
            revert PendleLPTokenAdaptor__CallIncreaseCardinality();
        }
        if (!oldestObservationSatisfied) {
            revert PendleLPTokenAdaptor__OldestObservationIsNotSatisfied();
        }
    }

    /// INTERNAL FUNCTIONS TO OVERRIDE ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
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
    ) internal virtual view override returns (PricingResult memory result) {}
}
