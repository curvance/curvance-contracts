// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { WAD } from "contracts/libraries/Constants.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";

abstract contract BaseWrappedAggregator is IChainlink {
    /// ERRORS ///

    error BaseWrappedAggregator__InvalidConfig();
    error BaseWrappedAggregator__UintToIntError();

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the current phase's aggregator address.
    /// @return The current phase's aggregator address.
    function aggregator() external view returns (address) {
        return address(this);
    }

    /// @notice Returns the maximum value that the aggregator can return.
    /// @return result The maximum value that the aggregator can return.
    function maxAnswer() external view returns (int192 result) {
        uint256 max = uint256(
            uint192(
                IChainlink(
                    IChainlink(underlyingAssetAggregator()).aggregator()
                ).maxAnswer()
            )
        );

        result = _boundAnswer(max);
    }

    /// @notice Returns the minimum value that the aggregator can returned.
    /// @return result The minimum value that the aggregator can returned.
    function minAnswer() external view returns (int192 result) {
        uint256 min = uint256(
            uint192(
                IChainlink(
                    IChainlink(underlyingAssetAggregator()).aggregator()
                ).minAnswer()
            )
        );

        result = _boundAnswer(min);
    }

    /// @notice Returns the number of decimals the aggregator responds with.
    /// @return The number of decimals the aggregator responds with.
    function decimals() external view returns (uint8) {
        return IChainlink(underlyingAssetAggregator()).decimals();
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
            underlyingAssetAggregator()
        ).latestRoundData();

        answer = (answer * _toInt256(getExchangeRate())) / _toInt256(WAD);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure returns (uint256) {
        return 5;
    }

    /// PUBLIC FUNCTIONS TO OVERRIDE ///

    /// @notice Returns the underlying aggregator address.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @return The underlying aggregator address.
    function underlyingAssetAggregator()
        public
        view
        virtual
        returns (address)
    {}

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @return The current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    function getExchangeRate() public view virtual returns (uint256) {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Bounds `answer` between int192 maximum and minimum values.
    /// @param answer The value to bound.
    /// @return The bounded answer.
    function _boundAnswer(uint256 answer) internal view returns (int192){
        answer = FixedPointMathLib.fullMulDiv(answer, getExchangeRate(), WAD);
        int256 intAnswer = _toInt256(answer);

        if (intAnswer > type(int192).max) {
            return type(int192).max;
        }
        if (intAnswer < type(int192).min) {
            return type(int192).min;
        }

        return _toInt192(intAnswer);
    }

    /// @notice Returns the downcasted int192 from int256, reverting on
    ///         overflow (when the input is less than smallest int192 or
    ///         greater than largest int192).
    /// @param value The int256 value to convert to int192.
    /// @return downcasted The downcasted int192 value.
    function _toInt192(
        int256 value
    ) internal pure returns (int192 downcasted) {
        downcasted = int192(value);
        if (downcasted != value) {
            revert BaseWrappedAggregator__UintToIntError();
        }
    }

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
