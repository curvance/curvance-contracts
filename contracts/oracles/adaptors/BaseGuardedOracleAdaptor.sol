// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { SECONDS_PER_YEAR, BASIS_POINTS } from "contracts/libraries/Constants.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";

abstract contract BaseGuardedOracleAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    struct GuardedModel {
        bool isSupported;
        uint256 timestampStart;
        uint256 basePrice;
        uint256 increasePerSecond;
    }

    /// CONSTANTS ///

    uint256 internal constant _MINIMUM_OVERFLOW_TIME_CHECK = 5;
    uint256 internal constant _MAXIMUM_BASE_PRICE_DIFFERENCE = 1000;
    /// @dev `bytes4(keccak256(bytes("BaseGuardedOracleAdaptor__InvalidConfig()")))`.
    uint256 internal constant _INVALID_CONFIG_SELECTOR = 0xd711ae2c;

    uint256 internal immutable _MAXIMUM_INCREASE_PER_YEAR;
    uint256 internal immutable _MINIMUM_INCREASE_PER_YEAR;
    uint256 internal immutable _MAXIMUM_TIMESTAMP_BUFFER;
    uint256 internal immutable _MINIMUM_TIMESTAMP_BUFFER;

    /// @notice Stores an assets guarded model, or not.
    /// @dev Asset => Guarded Model.
    mapping(address => GuardedModel) public guardedModels;

    /// EVENTS ///

    event NewGuardedModel(
        address asset,
        uint256 timestampStart,
        uint256 basePrice,
        uint256 increasePerYear
    );

    /// ERRORS ///

    error BaseGuardedOracleAdaptor__InvalidConfig();
    error BaseGuardedOracleAdaptor__NoGuardedModel();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) BaseOracleAdaptor(centralRegistry_) {
        _MAXIMUM_INCREASE_PER_YEAR = MAXIMUM_INCREASE_PER_YEAR;
        _MINIMUM_INCREASE_PER_YEAR = MINIMUM_INCREASE_PER_YEAR;
        _MAXIMUM_TIMESTAMP_BUFFER = MAXIMUM_TIMESTAMP_BUFFER;
        _MINIMUM_TIMESTAMP_BUFFER = MINIMUM_TIMESTAMP_BUFFER;
    }

    /// EXTERNAL FUNCTIONS ///

    function getBoundedPrice(uint256 asset) external view returns (uint256) {
        GuardedModel memory model = guardedModels[asset];
        if (!model.isSupported) {
            revert BaseGuardedOracleAdaptor__NoGuardedModel();
        }

        return ((block.timestamp - model.timestampStart) *
            model.increasePerSecond) + model.basePrice;
    }

    function setGuardedPriceConfig(
        address asset,
        uint256 increasePerYear,
        uint256 basePrice,
        uint256 timestampStart
    ) external {
        _checkMarketPermissions();
        
        // Convert `increasePerYear` from basis points to WAD.
        increasePerYear = increasePerYear * 1e14;

        if (timestampStart > block.timestamp) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        if (
            block.timestamp - timestampStart > _MAXIMUM_TIMESTAMP_BUFFER ||
            block.timestamp - timestampStart < _MINIMUM_TIMESTAMP_BUFFER
        ) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        if (
            increasePerYear > _MAXIMUM_INCREASE_PER_YEAR ||
            increasePerYear < _MINIMUM_INCREASE_PER_YEAR
        ) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        if (
            (_MINIMUM_OVERFLOW_TIME_CHECK * increasePerYear) + basePrice >
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

        PriceReturnData memory priceReturnData = this.getPrice(asset, true, true);
        uint256 oraclePrice = priceReturnData.price;

        if (boundedPriceHigh < oraclePrice || boundedPriceLow > oraclePrice) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        GuardedModel storage model = guardedModels[asset];
        model.isSupported = true;
        model.increasePerSecond = increasePerSecond;
        model.basePrice = basePrice;
        model.timestampStart = timestampStart;

        emit NewGuardedModel(asset, increasePerYear, basePrice, timestampStart);
    }

    /// INTERNAL FUNCTIONS ///

    function _boundPrice(
        address asset,
        uint256 price
    ) internal view override returns (uint256) {
        GuardedModel memory model = guardedModels[asset];
        if (!model.isSupported) {
            return price;
        }

        uint256 boundedPrice = ((block.timestamp - model.timestampStart) *
            model.increasePerSecond) + model.basePrice;
        return price > boundedPrice ? boundedPrice : price;
    }
}
