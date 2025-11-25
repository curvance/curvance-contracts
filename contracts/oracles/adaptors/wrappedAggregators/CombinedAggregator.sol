// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseWrappedAggregator, IChainlink } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

import { WAD, HEARTBEAT_GRACE_PERIOD } from "contracts/libraries/ConstantsLib.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

/// @title Curvance Combined Aggregator.
/// @notice Combines two price feeds together to return the price of an
///         asset in USD.
/// @dev Curvance combined aggregators are intended to combine any two
///      aggregator feeds together to price a new asset. Combined feeds can
///      be any onchain push based oracle that supports rounds of data with
///      the "latestRoundData" function interface (see "IChainlink").
///
///
///      These aggregators should then be listed in the corresponding adaptor
///      (e.g. "ChainlinkAdaptor", "RedstoneClassicAdaptor") to price assets
///      inside Curvance Markets.
///
///      The second aggregators heartbeat is explicitly checked here with the
///      former aggregators heartbeat checked in the corresponding adaptor.
///      An additional Price Guard can also be configured in here, specifically
///      for the secondary aggregator.
///
contract CombinedAggregator is BaseWrappedAggregator {
    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice The address of the second aggregator to combine prices
    ///         with `_assetAggregator`.
    IChainlink public immutable secondaryAggregator;

    /// @notice If zero is specified for a Redstone asset heartbeat,
    ///         this value is used instead, added 60 seconds incase of
    ///         transaction congestion delaying an update.
    /// @dev    1 days = 24 hours = 1,440 minutes = 86,400 seconds.
    uint256 public constant DEFAULT_HEARTBEAT =
        1 days + HEARTBEAT_GRACE_PERIOD;

    /// @notice Data for reviewing `secondaryAggregator` denominated in the
    ///         same value as aggregator.
    IOracleAdaptor.PriceGuard public pg;

    /// @notice The expanded decimal precision (10 ** decimals) for
    ///         `_secondaryAggregator`.
    uint256 internal immutable _secondaryDecimalPrecision;
    /// @notice The minimum amount of time allowed between `timestampStart`
    ///         and `block.timestamp` on `setGuardedPriceConfig` call.
    uint256 internal constant _MINIMUM_TIMESTAMP_BUFFER = 7 days;

    /// STORAGE ///

    uint256 public secondaryHeartbeat;

    /// EVENTS ///

    event PriceGuardUpdated(IOracleAdaptor.PriceGuard pg);

    /// ERRORS ///

    error CombinedAggregator__Unauthorized();
    error CombinedAggregator__InvalidValue();
    error CombinedAggregator__InvalidConfig();
    error CombinedAggregator__InvalidTimestamp();
    error CombinedAggregator__InvalidHeartbeat();
    error CombinedAggregator__MinPriceAboveCurrentPrice();
    error CombinedAggregator__UnusedFunction();

    /// CONSTRUCTOR ///
    
    constructor(
        ICentralRegistry cr,
        address _aggregator,
        address _secondaryAggregator,
        uint256 _secondaryHeartbeat,
        string memory id
    ) BaseWrappedAggregator(_aggregator, id) {
        CentralRegistryLib._isCentralRegistry(cr);
        centralRegistry = cr;

        (uint256 roundId, int256 answer,,uint256 updatedAt,) =
            IChainlink(_secondaryAggregator).latestRoundData();
        // This check should basically never fail but its here incase somehow
        // the deployer misconfigured the aggregator address, also doubles as
        // checking that the function call did not fail.
        if (answer <= 0 || updatedAt == 0 || roundId == 0) {
            revert BaseWrappedAggregator__InvalidConfig();
        }

        _secondaryHeartbeat = _setSecondaryHeartbeat(_secondaryHeartbeat);
        secondaryAggregator = IChainlink(_secondaryAggregator);
        _secondaryDecimalPrecision = 10 ** IChainlink(_secondaryAggregator).decimals();
    }

    /// @notice Sets a PriceGuard when pricing via `secondaryAggregator`.
    /// @param timestampStart When `ips` should start increasing `basePrice`
    ///                       raising the maximum price returned when pricing
    ///                       `asset`.
    /// @param ips The magnitude that `basePrice` should increase overtime
    ///            overtime from `timestampStart`, in `WAD`, in seconds.
    /// @param basePrice The base price that should be the maximum price
    ///                  returned when pricing `asset`.
    /// @param minPrice The minimum price that should be allowed to be
    ///                 returned when pricing `asset`.
    function setGuardedPriceConfig(
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) external {
        _checkMarketPermissions();

        // Validate timestamp configuration depending on whether dynamic scaling is 
        // enabled. If ips == 0, timestampStart must be exactly 0 
        // (unused in static mode).
        // Otherwise, enforce it is not in the future or too "now".
        if (ips == 0) {
            if (timestampStart != 0) {
                revert CombinedAggregator__InvalidTimestamp();
            }
        } else {
            if (
                timestampStart > block.timestamp ||
                block.timestamp - timestampStart < _MINIMUM_TIMESTAMP_BUFFER ||
                timestampStart == 0
            ) {
                revert CombinedAggregator__InvalidTimestamp();
            }
        }

        // Validate that growth rate will fit in 40 bit slot allocated.
        if (ips > type(uint40).max) {
            revert CombinedAggregator__InvalidConfig();
        }

        // Validate basePrice is not 0 and that base price will fit in the 
        // 88 bit slot allocated.
        if (basePrice == 0 || basePrice > type(uint88).max) {
            revert CombinedAggregator__InvalidConfig();
        }

        // Validate that min and max price logic are not inverted, we can then
        // skip the storage slot check since basePrice > minPrice.
        if (minPrice > basePrice) {
            revert CombinedAggregator__InvalidConfig();
        }

        // Validate the higher feed did not return an error.
        (, int256 answer,,uint256 updatedAt,) =
            IChainlink(secondaryAggregator).latestRoundData();

        if (block.timestamp - secondaryHeartbeat > updatedAt) {
            revert CombinedAggregator__InvalidConfig();
        }

        // Having a minimum price above the current price does not make sense,
        // implying that asset price behaves differently than our PriceGuard
        // assumes.
        // This will simply return `minPrice` if ips == 0 so can use internal
        // function to handle both cases.
        uint256 guardedMinPrice =
            _guardedPrice(block.timestamp - timestampStart, ips, minPrice);

        if (guardedMinPrice > _toUint256(answer)) {
            revert CombinedAggregator__MinPriceAboveCurrentPrice();
        }
        
        IOracleAdaptor.PriceGuard storage p = pg;

        // New `timestampStart` needs to start after the current one.
        if (p.timestampStart > timestampStart && timestampStart > 0) {
            revert CombinedAggregator__InvalidTimestamp();
        }

        p.timestampStart = uint40(timestampStart);
        p.ips = uint40(ips);
        p.basePrice = uint88(basePrice);
        p.minPrice = uint88(minPrice);

        emit PriceGuardUpdated(pg);
    }

    /// @notice Disables any PriceGuard active.
    function disableGuardedPriceConfig() external {
        _checkMarketPermissions();
        delete pg;
    }

    /// @notice Sets an heartbeat to check `secondaryAggregator` against.
    /// @param heartbeat The heartbeat to use when validating prices
    ///                  for `secondaryAggregator`. 0 = `DEFAULT_HEARTBEAT`.
    function setSecondaryHeartbeat(uint256 heartbeat) external {
        _checkMarketPermissions();
        secondaryHeartbeat = _setSecondaryHeartbeat(heartbeat);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the latest oracle data from the aggregator,
    ///         adjusted by the wrapper.
    /// @dev roundID, startedAt, and answeredInRound return values should not
    ///      be relied on for "correctness" because this combined feed is
    ///      only intended to work with our adaptor architecture.
    /// @return roundId The round ID from the aggregator for which the data
    ///                 was retrieved.
    ///         answer The price returned by the aggregator,
    ///                adjusted by the wrapper.
    ///         startedAt The timestamp the current round was started.
    ///         updatedAt The timestamp the current round last was updated.
    ///         answeredInRound The round ID of the round in which `answer`
    ///                         was computed.
    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) =
            _assetAggregator.latestRoundData();
        (, int256 secondaryAnswer,, uint256 secondaryUpdatedAt, ) = 
            secondaryAggregator.latestRoundData();

        // If the second heartbeat is stale we can bubble up timestamp of 0
        // to cause a _verifyData error code.
        if (block.timestamp - secondaryHeartbeat > secondaryUpdatedAt) {
            updatedAt = 0;
        }

        // Adjust `answer` by secondary answer to combine and divide by
        // secondary decimal precision.
        answer = _toInt256(FixedPointMathLib.fullMulDiv(
            _toUint256(answer),
            _adjustPrice(_toUint256(secondaryAnswer)), // Apply price guard if needed
            _secondaryDecimalPrecision)
        );
    }

    /// @notice Returns the adjusted `answer` based on the current exchange
    ///         rate between the wrapped asset and the underlying aggregator.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @param answer The answer to adjust based on current exchange rate value.
    /// @return result The adjusted oracle `answer`.
    function getAdjustedAnswer(
        int256 answer
    ) public view virtual override returns (int256 result) {
        (, int256 secondaryAnswer,,,) = secondaryAggregator.latestRoundData();
        // Adjust `answer` by secondary answer to combine and divide by
        // secondary decimal precision.
        result = _toInt256(FixedPointMathLib.fullMulDiv(
            _toUint256(answer),
            _adjustPrice(_toUint256(secondaryAnswer)),  // Apply price guard if needed
            _secondaryDecimalPrecision
        ));
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Validates heartbeat value to compare `secondaryAggregator`
    ///         against.
    /// @param heartbeat The heartbeat to use when validating prices
    ///                  for `secondaryAggregator`. 0 = `DEFAULT_HEARTBEAT`.
    /// @return The heartbeat value.
    function _setSecondaryHeartbeat(
        uint256 heartbeat
    ) internal pure returns (uint256) {
        // If we are not using the default heartbeat directly, apply
        // `HEARTBEAT_GRACE_PERIOD` to `heartbeat` to make sure it is included.
        heartbeat = heartbeat != 0 ?
            heartbeat + HEARTBEAT_GRACE_PERIOD : DEFAULT_HEARTBEAT;

        // Validate the feed heartbeat is not too long.
        if (heartbeat > DEFAULT_HEARTBEAT) {
            revert CombinedAggregator__InvalidHeartbeat();
        }

        return heartbeat;
    }
    
    /// @notice Helper function for adjusting received price if needed by
    ///         attached price guard.
    /// @param price The price to adjust.
    /// @return Returns the potentially adjusted price in 1e18 (WAD) scale.
    function _adjustPrice(
        uint256 price
    ) internal view returns (uint256) {
        // Adjust price based on any present price guards.
        IOracleAdaptor.PriceGuard memory p = pg;
        
        // Case where there is no base price at all, this indicates PriceGuard
        // is disabled, so can return price as is.
        if (p.basePrice == 0) {
            return price;
        }

        // Case where there is no realtime price increase so the PriceGuard
        // has static minimum/maximum guarded prices.
        if (p.ips == 0) {
            // If the price of the token drops below the minimum we return 0
            // to immediately bubble up a pricing error.
            if (price < p.minPrice) {
                return 0;
            }

            return price > p.basePrice ? p.basePrice : price;
        }

        // Case with dynamic minimum/maximum guarded prices.

        // Calculate how much to shift up minimum and maximum values from
        // scaling guarded prices.
        uint256 timePassed = block.timestamp - p.timestampStart;
        uint256 min = _guardedPrice(timePassed, p.ips, p.minPrice);

        // If the price of the token drops below the minimum we return 0 to
        // immediately bubble up a pricing error.
        if (price < min) {
            return 0;
        }
        
        uint256 max = _guardedPrice(timePassed, p.ips, p.basePrice);
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
        r = FixedPointMathLib.fullMulDiv(price, ((timePassed * ips) + WAD), WAD);
    }

    /// @notice Converts int256 `value` to uint256 form.
    function _toUint256(int256 value) internal pure returns (uint256 result) {
        if (value < 0) {
            revert CombinedAggregator__InvalidValue();
        }
        result = uint256(value);
    }

    /// @notice Checks whether the caller has sufficient permissioning.
    function _checkMarketPermissions() internal view {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            revert CombinedAggregator__Unauthorized();
        }
    }
}
