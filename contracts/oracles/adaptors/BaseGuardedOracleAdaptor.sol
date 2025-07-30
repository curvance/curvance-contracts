// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { SECONDS_PER_YEAR } from "contracts/libraries/Constants.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

abstract contract BaseGuardedOracleAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    struct GuardedModel {
        bool isSupported;
        uint256 timestampStart;
        uint256 baseValue;
        uint256 increasePerSecond;
    }

    /// CONSTANTS ///

    uint256 internal constant _MINIMUM_OVERFLOW_TIME_CHECK = 5;
    /// @dev `bytes4(keccak256(bytes("BaseProtectedFeed__InvalidConfig()")))`.
    uint256 internal constant _INVALID_CONFIG_SELECTOR = 0x3c65d2ab;

    uint256 internal immutable _MINIMUM_BASE_PRICE;
    uint256 internal immutable _MINIMUM_TIMESTAMP_START;
    uint256 internal immutable _MINIMUM_INCREASE_PER_YEAR;
    uint256 internal immutable _MAXIMUM_INCREASE_PER_YEAR;

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

    error BaseProtectedFeed__Unauthorized();
    error BaseProtectedFeed__InvalidConfig();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_BASE_PRICE,
        uint256 MINIMUM_TIMESTAMP_START
    ) BaseOracleAdaptor(centralRegistry_) {
        _MAXIMUM_INCREASE_PER_YEAR = MAXIMUM_INCREASE_PER_YEAR;
        _MINIMUM_INCREASE_PER_YEAR = MINIMUM_INCREASE_PER_YEAR;
        _MINIMUM_BASE_PRICE = MINIMUM_BASE_PRICE;
        _MINIMUM_TIMESTAMP_START = MINIMUM_TIMESTAMP_START;
    }

    /// EXTERNAL FUNCTIONS ///

    function setGuardedPriceConfig(
        address asset,
        uint256 increasePerYear,
        uint256 basePrice,
        uint256 timestampStart
    ) external {
        _checkMarketPermissions();
        
        // Convert `increasePerYear` from basis points to WAD.
        increasePerYear = increasePerYear * 1e14;

        if (basePrice < _MINIMUM_BASE_PRICE) {
            _revert(_INVALID_CONFIG_SELECTOR);
        }

        if (
            timestampStart < _MINIMUM_TIMESTAMP_START ||
            timestampStart > block.timestamp
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

        GuardedModel storage model = guardedModels[asset];
        model.increasePerSecond = increasePerYear/ SECONDS_PER_YEAR;
        model.baseValue = basePrice;
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

        uint256 boundedPrice =
            ((block.timestamp - model.timestampStart) * model.increasePerSecond)
                + model.baseValue;
        return price > boundedPrice ? boundedPrice : price;
    }
}
