// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IChainlink {
    /// @notice Returns the number of decimals the aggregator responds with.
    function decimals() external view returns (uint8);

    /// @notice Returns the latest oracle data from the aggregator.
    /// @return roundId The round ID from the aggregator for which the data
    ///                 was retrieved.
    ///         answer The price returned by the aggregator.
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
        );
}
