// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseOracleAdaptor, ICentralRegistry } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { PendlePtOracleLib } from "contracts/libraries/external/pendle/PendlePtOracleLib.sol";

import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

contract PendlePrincipalTokenAdaptor is BaseOracleAdaptor {
    using PendlePtOracleLib for IPMarket;

    /// TYPES ///

    /// @notice Stores configuration data for Pendle PT price sources.
    /// @param market The Pendle market for the Principal Token being priced.
    /// @param twapDuration The twap duration to use when pricing.
    /// @param quoteAsset The asset the twap quote is provided in.
    /// @param quoteAssetDecimals The decimals `quoteAsset` twap quote
    ///                           is provided in.
    struct AssetConfig {
        IPMarket market;
        uint32 twapDuration;
        address quoteAsset;
        uint8 quoteAssetDecimals;
    }

    /// CONSTANTS ///

    /// @notice The minimum acceptable twap duration when pricing.
    uint32 public constant MINIMUM_TWAP_DURATION = 12;

    /// @notice Current networks ptOracle.
    /// @dev for mainnet use 0x414d3C8A26157085f286abE3BC6E1bb010733602.
    IPendlePTOracle public immutable ptOracle;

    /// STORAGE ///

    /// @notice Price feed configuration data for an asset.
    /// @dev Token address => Price feed configuration for `asset`.
    mapping(address => AssetConfig) public assetConfig;

    /// EVENTS ///

    event AssetAdded(address asset, AssetConfig config, bool isUpdate);

    /// ERRORS ///

    error PendlePrincipalTokenAdaptor__WrongMarket();
    error PendlePrincipalTokenAdaptor__WrongQuote();
    error PendlePrincipalTokenAdaptor__TwapDurationIsLessThanMinimum();
    error PendlePrincipalTokenAdaptor__CallIncreaseCardinality();
    error PendlePrincipalTokenAdaptor__OldestObservationIsNotSatisfied();
    error PendlePrincipalTokenAdaptor__QuoteAssetIsNotSupported();

    /// CONSTRUCTOR ///

    /// @param cr The address of central registry.
    constructor(
        ICentralRegistry cr,
        IPendlePTOracle ptOracle_
    ) BaseOracleAdaptor(cr) {
        ptOracle = ptOracle_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of a given Pendle pt.
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

        AssetConfig memory config = assetConfig[asset];
        // Get PT to underlying asset ratio conversion.
        uint256 ptRate = config.market.getPtToAssetRate(config.twapDuration);

        (uint256 price, uint256 errorCode) =
            CommonLib._oracleManager(centralRegistry)
                .getPrice(config.quoteAsset, inUSD, getLower);

        // Validate we did not run into any errors pricing the quote asset.
        if (errorCode > 0) {
            result.hadError = true;
            return result;
        }

        // Multiply the quote asset price by the ptRate
        // to get the Principal Token fair value.
        result.price = (price * ptRate) / WAD;
        result.inUSD = inUSD;
    }

    /// @notice Adds pricing support for `asset`, a Pendle principal token.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the Pendle principal token to add pricing
    ///              support for.
    /// @param config The adaptor data needed to add `asset`.
    function addAsset(address asset, AssetConfig memory config) external {
        _checkElevatedPermissions();

        // Make sure pt and market match.
        (IStandardizedYield sy, IPPrincipalToken pt, ) = config
            .market
            .readTokens();

        // Validate pt pulled from market matches `asset`.
        if (address(pt) != asset) {
            revert PendlePrincipalTokenAdaptor__WrongMarket();
        }

        // Validate the parameter twap duration is within acceptable bounds.
        if (config.twapDuration < MINIMUM_TWAP_DURATION) {
            revert PendlePrincipalTokenAdaptor__TwapDurationIsLessThanMinimum();
        }

        // Make sure quote asset is the same as SY `assetInfo.assetAddress`.
        (, address assetAddress, ) = sy.assetInfo();
        if (assetAddress != config.quoteAsset) {
            revert PendlePrincipalTokenAdaptor__WrongQuote();
        }

        // Make sure the underlying PT TWAP is working.
        _checkPtTwap(address(config.market), config.twapDuration);

        // Validate we support the pricing quote asset for this principal token.
        if (!CommonLib._oracleManager(centralRegistry)
                .isSupportedAsset(config.quoteAsset)
        ) {
            revert PendlePrincipalTokenAdaptor__QuoteAssetIsNotSupported();
        }

        // Save `config` and update mapping that we support `asset` now.
        assetConfig[asset] = config;

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
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 7;
    }

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
            revert PendlePrincipalTokenAdaptor__CallIncreaseCardinality();
        }

        if (!oldestObservationSatisfied) {
            revert PendlePrincipalTokenAdaptor__OldestObservationIsNotSatisfied();
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
    ) internal view virtual override returns (PricingResult memory result) {}

    /// @notice Wipes `asset` pricing configurations from this adaptor.
    /// @param asset The address of the asset to wipe pricing support of.
    function _wipeAssetConfigs(address asset) internal override {
        delete assetConfig[asset];
    }
}