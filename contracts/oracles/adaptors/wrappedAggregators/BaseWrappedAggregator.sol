// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";

abstract contract BaseWrappedAggregator is IChainlink {
    /// ERRORS ///

    error BaseWrappedAggregator__InvalidConfig();
    error BaseWrappedAggregator__UintToIntError();

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the number of decimals the aggregator responds with.
    /// @return The number of decimals the aggregator responds with.
    function decimals() external view returns (uint8) {
        return IChainlink(underlyingAggregator()).decimals();
    }

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
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = IChainlink(
            underlyingAggregator()
        ).latestRoundData();

        answer = (answer * _toInt256(getExchangeRate())) / _toInt256(WAD);
    }

    /// PUBLIC FUNCTIONS TO OVERRIDE ///

    /// @notice Returns the underlying aggregator address.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @return The underlying aggregator address.
    function underlyingAggregator() public view virtual returns (address) {}

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view virtual returns (uint256) {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Converts an unsigned uint256 into a signed int256.
    /// @param value The uint256 value to convert to int256.
    /// @return The converted int256 value.
    function _toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max`
        //       is guaranteed to be positive
        if (value > uint256(type(int256).max)) {
            revert BaseWrappedAggregator__UintToIntError();
        }
        return int256(value);
    }
}
