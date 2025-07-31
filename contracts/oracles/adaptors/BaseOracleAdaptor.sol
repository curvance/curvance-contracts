// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { SECONDS_PER_YEAR, WAD, BASIS_POINTS } from "contracts/libraries/Constants.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleAdaptor, PriceReturnData, PriceGuard } from "contracts/interfaces/IOracleAdaptor.sol";

abstract contract BaseOracleAdaptor is IOracleAdaptor {
    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @dev `bytes4(keccak256(bytes("BaseOracleAdaptor__Unauthorized()")))`.
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0xfb56769a;
    /// @dev `bytes4(keccak256(bytes("BaseOracleAdaptor__InvalidConfig()")))`.
    uint256 internal constant _INVALID_CONFIG_SELECTOR = 0xbdb91f6b;
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
    error BaseOracleAdaptor__InvalidCentralRegistry();
    error BaseOracleAdaptor__InvalidConfig();
    
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert BaseOracleAdaptor__InvalidCentralRegistry();
        }

        _MAXIMUM_INCREASE_PER_YEAR = MAXIMUM_INCREASE_PER_YEAR;
        _MINIMUM_INCREASE_PER_YEAR = MINIMUM_INCREASE_PER_YEAR;
        _MAXIMUM_TIMESTAMP_BUFFER = MAXIMUM_TIMESTAMP_BUFFER;
        _MINIMUM_TIMESTAMP_BUFFER = MINIMUM_TIMESTAMP_BUFFER;

        centralRegistry = centralRegistry_;
    }

    /// EXTERNAL FUNCTIONS ///

    function getPriceGuard(
        address asset,
        bool inUSD
    ) external view returns (PriceGuard memory) {
        return priceGuards[asset][inUSD];
    }

    function disableGuardedPriceConfig(
        address asset,
        bool inUSD
    ) external {
        _checkMarketPermissions();

        delete priceGuards[asset][inUSD];
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

        if (guardType == 0 || guardType > 3) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }
        
        if (timestampStart > block.timestamp) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        if (minPrice > basePrice) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        if (
            block.timestamp - timestampStart > _MAXIMUM_TIMESTAMP_BUFFER ||
            block.timestamp - timestampStart < _MINIMUM_TIMESTAMP_BUFFER
        ) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        // Convert `increasePerYear` from basis points to WAD.
        increasePerYear = increasePerYear * 1e14;

        if (
            increasePerYear > _MAXIMUM_INCREASE_PER_YEAR ||
            increasePerYear < _MINIMUM_INCREASE_PER_YEAR
        ) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        if (
            (_MINIMUM_YEAR_OVERFLOW * increasePerYear) + basePrice >
            type(uint240).max
            ) {
                _revert(_INVALID_CONFIG_SELECTOR);
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

        PriceReturnData memory priceReturnData = this.getPrice(asset, inUSD, true);
        uint256 oraclePrice = priceReturnData.price;

        if (boundedPriceHigh < oraclePrice || boundedPriceLow > oraclePrice) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        PriceGuard storage model = priceGuards[asset][inUSD];
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

    /// @notice Called by OracleManager to price an asset.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD A boolean to determine if the price should be returned in
    ///              USD or not.
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return A structure containing the price, error status,
    ///         and the quote format of the price.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view virtual returns (PriceReturnData memory);

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
    ) internal virtual view returns (bool) {
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

    /// @notice Helper function for normalizing (converting prices in
    ///         different forms to a common scale) prices received from
    ///         various oracle adaptors.
    /// @param price The price to normalize.
    /// @param decimals The decimal precision `price` is reported in.
    /// @return result Returns the normalized price in 1e18 (WAD) scale.
    function _normalizePrice(
        address asset,
        bool inUSD,
        uint256 price,
        uint256 decimals
    ) internal view returns (uint256 result) {
        result = _boundPrice(
            asset,
            inUSD,
            FixedPointMathLib.fullMulDiv(price, WAD, 10 ** decimals)
        );
    }

    /// @notice Helper function to check whether `price` would overflow
    ///         based on a uint240 maximum.
    /// @param price The price to check against overflow.
    /// @return result Whether `price` will overflow on conversion to uint240.
    function _checkOverflow(
        uint256 price
    ) internal pure returns (bool result) {
        result = price > type(uint240).max;
    }

    /// @notice Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @notice Checks whether the caller has sufficient permissioning.
    function _checkMarketPermissions() internal view {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /// EXTERNAL FUNCTIONS TO OVERRIDE ///

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external virtual view returns (uint256);

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function removeAsset(address asset) external virtual;

    /// INTERNAL FUNCTIONS TO OVERRIDE ///

    function _boundPrice(
        address asset,
        bool inUSD,
        uint256 price
    ) internal view returns (uint256) {
        PriceGuard memory pg = priceGuards[asset][inUSD];
        if (pg.guardType == 0) {
            return price;
        }

        if (price < pg.minPrice) {
            return pg.minPrice;
        }

        if (pg.guardType == 1) {
            return price > pg.basePrice ? pg.basePrice : price;
        }

        uint256 boundedPrice = ((block.timestamp - pg.timestampStart) *
            pg.increasePerSecond) + pg.basePrice;
        return price > boundedPrice ? boundedPrice : price;
    }
}
