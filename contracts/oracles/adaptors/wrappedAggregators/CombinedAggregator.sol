// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseWrappedAggregator, IChainlink } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

/// @title Curvance Combined Aggregator.
/// @notice Combines two price feeds together to return the price of an
///         asset in USD.
/// @dev Curvance combined aggregators are intended to combine any two
///      aggregator feeds together to price a new asset. Combined feeds can
///      be any onchain push based oracle that supports rounds of data with
///      the "latestRoundData" function interface (see "IChainlink").
///
///      The deviation assigned in the corresponding adaptor MUST be the more
///      restrictive of the two feeds. If one feed is 1 hour heartbeat and
///      another is 24 hour heartbeat the assigned heartbeat should be 1 hour.
///
///
///      These aggregators should then be listed in the corresponding adaptor
///      (e.g. "ChainlinkAdaptor", "RedstoneClassicAdaptor") to price assets
///      inside Curvance Markets.
///
contract CombinedAggregator is BaseWrappedAggregator {
    /// CONSTANTS ///

    /// @notice The address of the second aggregator to combine prices
    ///         with `_assetAggregator`.
    IChainlink internal immutable _secondaryAggregator;
    /// @notice The expanded decimal precision (10 ** decimals) for
    ///         `_secondaryAggregator`, in int256 form.
    int256 internal immutable _secondaryDecimalPrecision;

    /// CONSTRUCTOR ///
    
    constructor(
        address aggregator,
        address secondaryAggregator,
        string memory id
    ) BaseWrappedAggregator(aggregator, id) {
        _secondaryAggregator = IChainlink(secondaryAggregator);
        _secondaryDecimalPrecision =
            _toInt256(10 ** IChainlink(secondaryAggregator).decimals());
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the latest oracle data from the aggregator,
    ///         adjusted by the wrapper.
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
            _secondaryAggregator.latestRoundData();

        // Adjust `answer` by secondary answer to combine and divide by
        // secondary decimal precision.
        answer = FixedPointMathLib
            .fullMulDiv(answer, secondaryAnswer,  _secondaryDecimalPrecision);
        // Use the timestamp of the stalest of the two feeds.
        updatedAt = updatedAt > secondaryUpdatedAt ?
            secondaryUpdatedAt : updatedAt;
    }

    /// @notice Returns the adjusted `answer` based on the current exchange
    ///         rate between the wrapped asset and the underlying aggregator.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @param answer The answer to adjust based on current exchange rate value.
    /// @return result The adjusted oracle `answer`.
    function getAdjustedAnswer(
        int256 answer
    ) public view virtual override returns (int256 result) {
        (, int256 secondaryAnswer,,,) = _secondaryAggregator.latestRoundData();
        // Adjust `answer` by secondary answer to combine and divide by
        // secondary decimal precision.
        result = FixedPointMathLib
            .fullMulDiv(answer, secondaryAnswer,  _secondaryDecimalPrecision);
    }
}
