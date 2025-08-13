// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CommonLib } from "contracts/libraries/CommonLib.sol";
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

    /// @notice The maximum price allowed to be returned by an oracle adaptor.
    uint256 internal constant _MAXIMUM_PRICE_ALLOWED = type(uint240).max;
    /// @notice The minimum amount of time allowed between `timestampStart`
    ///         and `block.timestamp` on `setGuardedPriceConfig` call.
    uint256 internal constant _MINIMUM_TIMESTAMP_BUFFER = 7 days;

    /// STORAGE ///

    /// @notice Whether an asset is supported by the Oracle Adaptor or not.
    /// @dev Asset => Supported by Adaptor.
    mapping(address => bool) public isSupportedAsset;
    /// @notice Token price guard configuration for pricing an asset.
    /// @dev Token address => inUSD => Price Guard configuration.
    mapping(address => mapping(bool => PriceGuard)) public priceGuards;

    /// EVENTS ///

    event AssetRemoved(address asset);
    event PriceGuardUpdated(PriceGuard pg);

    /// ERRORS ///

    error BaseOracleAdaptor__Unauthorized();
    error BaseOracleAdaptor__NoPriceGuard();
    error BaseOracleAdaptor__InvalidConfig();
    error BaseOracleAdaptor__AssetIsNotSupported();
    
    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;
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

    /// @notice Returns PriceGuard data for pricing `asset` denominated either
    ///         USD or native tokens depending on `inUSD`.
    /// @param asset The address of the asset to retrieve any PriceGuard data on.
    /// @param inUSD Specifies whether the PriceGuard returned should be in
    ///              USD (true) or a chain's native token (false).
    function getPriceGuard(
        address asset,
        bool inUSD
    ) external view returns (PriceGuard memory) {
        return priceGuards[asset][inUSD];
    }

    /// @notice Sets a PriceGuard when pricing `asset` denominated either USD
    ///         or native tokens depending on `inUSD`.
    /// @param asset The address of the asset to set a PriceGuard data on.
    /// @param inUSD Specifies whether the PriceGuard should be in
    ///              USD (true) or a chain's native token (false).
    /// @param guardType The type of PriceGuard to set on `asset`. 
    ///                  Where:
    ///                  1: Indicates a static maximum of `basePrice` and
    ///                     minimum of `minPrice`.
    ///                  2: Indicates an ever increasing maximum of
    ///                     `basePrice` and minimum of `minPrice` continually
    ///                     growing by `increasePerYear` % per year.
    /// @param timestampStart When `increasePerYear` should start increasing
    ///                       `basePrice` raising the maximum price returned
    ///                       when pricing `asset`.
    /// @param ips The magnitude that `basePrice` should increase overtime
    ///            overtime from `timestampStart`, in `WAD`, in seconds.
    /// @param basePrice The base price that should be the maximum price
    ///                  returned when pricing `asset`.
    /// @param minPrice The minimum price that should be allowed to be
    ///                 returned when pricing `asset`.
    function setGuardedPriceConfig(
        address asset,
        bool inUSD,
        uint256 guardType,
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) external {
        _checkMarketPermissions();

        // Validate that the intended guardType actually exists (type 1 / 2).
        if (guardType == 0 || guardType > 2) {
            revert BaseOracleAdaptor__InvalidConfig();
        }
        
        // Validate the starting timestamp is not in the future or too "now".
        if (
            timestampStart > block.timestamp ||
            block.timestamp - timestampStart < _MINIMUM_TIMESTAMP_BUFFER
        ) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        // Validate that growth rate will fit in 40 bit slot allocated.
        if (ips > type(uint40).max) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        // Validate that max price will fit in the 96 bit slot allocated.
        if (basePrice > type(uint96).max) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        // Validate that min and max price logic are not inverted and that the
        // minimum price will not overflow.
        if (minPrice > basePrice || minPrice > type(uint80).max) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        PricingResult memory result = this.getPrice(asset, inUSD, true);

        // Having a minimum price above the current price does not make sense,
        // implying that asset price behaves differently than our PriceGuard
        // assumes.
        if (minPrice > result.price) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        PriceGuard storage pg = priceGuards[asset][inUSD];

        // New `timestampStart` needs to start after the current one.
        if (pg.timestampStart > timestampStart) {
            revert BaseOracleAdaptor__InvalidConfig();
        }

        pg.timestampStart = uint40(timestampStart);
        pg.ips = uint40(ips);
        pg.basePrice = uint96(basePrice);
        pg.minPrice = uint80(minPrice);

        emit PriceGuardUpdated(pg);
    }

    /// @notice Disables any PriceGuard active when pricing `asset`
    ///         denominated either USD or native tokens depending on `inUSD`.
    /// @param asset The address of the asset to disable any PriceGuard data on.
    /// @param inUSD Specifies whether the PriceGuard disabled should be in
    ///              USD (true) or a chain's native token (false).
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
        CommonLib._oracleManager(centralRegistry).notifyFeedRemoval(asset);
        
        emit AssetRemoved(asset);
    }

    /// INTERNAL FUNCTIONS ///
    
    /// @notice Validates the feed data based on various constraints.
    /// @dev Checks if the value is within a specific range
    ///      and if the data is not outdated.
    /// @param value The value that is retrieved from the feed data.
    /// @param timestamp The time at which the value was last updated.
    /// @param heartbeat The maximum allowed time difference between
    ///                  current time and 'timestamp'.
    /// @return A boolean indicating whether the feed data had an error
    ///         (true = error, false = no error).
    function _verifyData(
        uint256 value,
        uint256 timestamp,
        uint256 heartbeat
    ) internal view virtual returns (bool) {
        // Validate `value` is not at or above type(uint240).max.
        if (value >= _MAXIMUM_PRICE_ALLOWED) {
            return true;
        }

        // Validate `value` is not at or below 0.
        if (value <= 0) {
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
        
        // Case where there is no base price at all, this indicates PriceGuard
        // is disabled, so can return price as is.
        if (pg.basePrice == 0) {
            return price;
        }

        // Case where there is no realtime price increase so the PriceGuard
        // has static minimum/maximum guarded prices.
        if (pg.ips == 0) {
            if (price < pg.minPrice) {
                return pg.minPrice;
            }

            return price > pg.basePrice ? pg.basePrice : price;
        }

        // Case with dynamic minimum/maximum guarded prices.

        // Calculate how much to shift up minimum and maximum values from
        // scaling guarded prices.
        uint256 timePassed = block.timestamp - pg.timestampStart;
        uint256 min = _guardedPrice(timePassed, pg.ips, pg.minPrice);

        if (price < min) {
            return min;
        }
        
        uint256 max = _guardedPrice(timePassed, pg.ips, pg.basePrice);
        return price > max ? max : price;
    }

    /// @notice Calculated the guarded price value to compare an oracle feeds
    ///         calculated price against.
    /// @notice timePassed The time passed since dynamic price increase
    ///                    started.
    /// @notice ips The increase per second relative applied to `price`,
    ///             in `WAD`.
    /// @notice price The starting price to calculate the guarded price from,
    ///               increased by `ips` overtime.
    function _guardedPrice(
        uint256 timePassed,
        uint256 ips,
        uint256 price
    ) internal pure returns (uint256 r) {
        r = FixedPointMathLib.mulDiv(price, ((timePassed * ips) + WAD), WAD);
    }

    /// @notice Helper function to check whether `price` would overflow
    ///         based on a uint240 maximum.
    /// @param price The price to check against overflow.
    /// @return o Whether `price` will overflow on conversion to uint240.
    function _checkOverflow(uint256 price) internal pure returns (bool o) {
        o = price > _MAXIMUM_PRICE_ALLOWED;
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