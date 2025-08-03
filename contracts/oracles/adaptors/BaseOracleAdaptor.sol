// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { SECONDS_PER_YEAR, WAD, BASIS_POINTS } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";

abstract contract BaseOracleAdaptor is IOracleAdaptor {
    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    uint256 internal constant _MINIMUM_YEAR_OVERFLOW = 5;
    uint256 internal constant _MAXIMUM_BASE_PRICE_DIFFERENCE = 1000;

    uint256 internal immutable _MAXIMUM_INCREASE_PER_YEAR;
    uint256 internal immutable _MINIMUM_INCREASE_PER_YEAR;
    uint256 internal immutable _MAXIMUM_TIMESTAMP_BUFFER;
    uint256 internal immutable _MINIMUM_TIMESTAMP_BUFFER;

    /// STORAGE ///

    /// @notice Whether an asset is supported by the Oracle Adaptor or not.
    /// @dev Asset => Supported by Adaptor.
    mapping(address => bool) public isSupportedAsset;
    /// @notice Token price guard configuration for pricing an asset.
    /// @dev Token address => inUSD => Price Guard configuration.
    mapping(address => mapping(bool => PriceGuard)) public priceGuards;

    /// EVENTS ///

    event AssetRemoved(address asset);
    event PriceGuardUpdated(
        address asset,
        bool inUSD,
        uint256 timestampStart,
        uint256 increasePerYear,
        uint256 basePrice,
        uint256 minPrice
    );

    /// ERRORS ///

    error BaseOracleAdaptor__Unauthorized();
    error BaseOracleAdaptor__NoPriceGuard();
    error BaseOracleAdaptor__InvalidConfig();
    error BaseOracleAdaptor__AssetIsNotSupported();
    
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry cr,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;

        _MAXIMUM_INCREASE_PER_YEAR = MAXIMUM_INCREASE_PER_YEAR;
        _MINIMUM_INCREASE_PER_YEAR = MINIMUM_INCREASE_PER_YEAR;
        _MAXIMUM_TIMESTAMP_BUFFER = MAXIMUM_TIMESTAMP_BUFFER;
        _MINIMUM_TIMESTAMP_BUFFER = MINIMUM_TIMESTAMP_BUFFER;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Retrieves the price of `asset`, in `inUSD` price form.
    /// @param asset The address of the asset to retrieve a price for.
    /// @param inUSD Specifies whether the price format should be in USD (true)
    ///              or a chain's native token (false).
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function getPrice(
        address asset,
        bool inUSD,
        bool /* getLower */
    ) external view virtual override returns (PricingResult memory result) {
        _checkSupportedAsset(asset);

        result = _getPrice(asset, inUSD);
    }

    function getPriceGuard(
        address asset,
        bool inUSD
    ) external view returns (PriceGuard memory) {
        return priceGuards[asset][inUSD];
    }

    function setGuardedPriceConfig(
        address asset,
        bool inUSD,
        uint256 guardType,
        uint256 increasePerYear,
        uint256 timestampStart,
        uint256 basePrice,
        uint256 minPrice
    ) external {
        _checkMarketPermissions();

        if (guardType == 0 || guardType > 2) {
            revert BaseOracleAdaptor__InvalidConfig();
        }
        
        if (timestampStart > block.timestamp) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        if (minPrice > basePrice) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        if (
            block.timestamp - timestampStart > _MAXIMUM_TIMESTAMP_BUFFER ||
            block.timestamp - timestampStart < _MINIMUM_TIMESTAMP_BUFFER
        ) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        // Convert `increasePerYear` from basis points to WAD.
        increasePerYear = increasePerYear * 1e14;

        if (
            increasePerYear > _MAXIMUM_INCREASE_PER_YEAR ||
            increasePerYear < _MINIMUM_INCREASE_PER_YEAR
        ) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        if (
            (_MINIMUM_YEAR_OVERFLOW * increasePerYear) + basePrice >
            type(uint240).max
            ) {
                revert BaseOracleAdaptor__InvalidConfig();
        }

        uint256 increasePerSecond = increasePerYear / SECONDS_PER_YEAR;

        uint256 boundedPrice =
            ((block.timestamp - timestampStart) * increasePerSecond) + basePrice;
        uint256 boundedPriceHigh = FixedPointMathLib.mulDiv(
            boundedPrice,
            (BASIS_POINTS + _MAXIMUM_BASE_PRICE_DIFFERENCE),
            BASIS_POINTS
        );
        uint256 boundedPriceLow = FixedPointMathLib.mulDiv(
            boundedPrice,
            (BASIS_POINTS - _MAXIMUM_BASE_PRICE_DIFFERENCE),
            BASIS_POINTS
        );

        PricingResult memory result = this.getPrice(asset, inUSD, true);
        uint256 oraclePrice = result.price;

        if (boundedPriceHigh < oraclePrice || boundedPriceLow > oraclePrice) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        PriceGuard storage model = priceGuards[asset][inUSD];

        // New `timestampStart` needs to start after the current one.
        if (model.timestampStart > timestampStart) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        model.guardType = guardType;
        model.increasePerSecond = increasePerSecond;
        model.timestampStart = timestampStart;
        model.basePrice = basePrice;
        model.minPrice = minPrice;

        emit PriceGuardUpdated(
            asset,
            inUSD,
            guardType,
            increasePerYear,
            basePrice,
            timestampStart
        );
    }

    function disableGuardedPriceConfig(address asset, bool inUSD) external {
        _checkMarketPermissions();
        delete priceGuards[asset][inUSD];
    }

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function removeAsset(address asset) external {
        _checkElevatedPermissions();
        _checkSupportedAsset(asset);

        // Notify the adaptor to stop supporting the asset.
        delete isSupportedAsset[asset];
        _wipeAssetConfigs(asset);

        // Notify the Oracle Manager that we are going to stop supporting
        // the asset.
        IOracleManager(centralRegistry.oracleManager()).notifyFeedRemoval(
            asset
        );
        
        emit AssetRemoved(asset);
    }

    /// INTERNAL FUNCTIONS ///
    
    /// @notice Validates the feed data based on various constraints.
    /// @dev Checks if the value is within a specific range
    ///      and if the data is not outdated.
    /// @param value The value that is retrieved from the feed data.
    /// @param timestamp The time at which the value was last updated.
    /// @param max The maximum value allowed of `value`.
    /// @param min The minimum value allowed of `value`.
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
        // Validate `value` is not at or above the maximum value allowed.
        if (value >= max) {
            return true;
        }

        // Validate `value` is not at or below the min value allowed.
        if (value <= min) {
            return true;
        }

        // Validate the price returned is not stale.
        if (block.timestamp - timestamp > heartbeat) {
            return true;
        }

        return false;
    }

    /// @notice Helper function for adjusting received price into WAD form
    ///         received from various oracle adaptors.
    /// @param price The price to adjust.
    /// @param decimals The decimal precision `price` is reported in.
    /// @return Returns the potentially adjusted price in 1e18 (WAD) scale.
    function _adjustPrice(
        address asset,
        bool inUSD,
        uint256 price,
        uint256 decimals
    ) internal view returns (uint256) {
        // Normalize price to 18 decimals (WAD).
        if (decimals != 18) {
            price = FixedPointMathLib.fullMulDiv(price, WAD, 10 ** decimals);
        }
        
        // Adjust price based on any present price guards.
        PriceGuard memory pg = priceGuards[asset][inUSD];
        
        // Case with no minimum/maximum guarded prices.
        if (pg.guardType == 0) {
            return price;
        }

        // Case with static minimum/maximum guarded prices.
        if (pg.guardType == 1) {
            if (price < pg.minPrice) {
                return pg.minPrice;
            }

            return price > pg.basePrice ? pg.basePrice : price;
        }

        // Case with dynamic minimum/maximum guarded prices.

        // Calculate how much to shift up minimum and maximum values from
        // scaling guarded prices.
        uint256 dynamicAdjustment = ((block.timestamp - pg.timestampStart) *
            pg.increasePerSecond);
        uint256 boundedMin = pg.minPrice + dynamicAdjustment;

        if (price < boundedMin) {
            return boundedMin;
        }
        
        uint256 boundedMax = pg.basePrice + dynamicAdjustment;
        return price > boundedMax ? boundedMax : price;
    }

    /// @notice Helper function to check whether `price` would overflow
    ///         based on a uint240 maximum.
    /// @param price The price to check against overflow.
    /// @return o Whether `price` will overflow on conversion to uint240.
    function _checkOverflow(uint256 price) internal pure returns (bool o) {
        o = price > type(uint240).max;
    }

    /// @notice Checks whether `asset` is supported by the adaptor or not.
    function _checkSupportedAsset(address asset) internal view {
        // Validate we support pricing `asset`.
        if (!isSupportedAsset[asset]) {
            revert BaseOracleAdaptor__AssetIsNotSupported();
        }
    }

    /// @notice Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert BaseOracleAdaptor__Unauthorized();
        }
    }

    /// @notice Checks whether the caller has sufficient permissioning.
    function _checkMarketPermissions() internal view {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            revert BaseOracleAdaptor__Unauthorized();
        }
    }

    /// EXTERNAL FUNCTIONS TO OVERRIDE ///

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external view virtual returns (uint256);

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
    ) internal view virtual returns (PricingResult memory result);

    /// @notice Wipes supported asset pricing configs from an adaptor.
    function _wipeAssetConfigs(address /*asset*/ ) internal virtual;
}