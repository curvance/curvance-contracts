// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";

/// @title Curvance Static Price Aggregator.
/// @notice Returns a static price in aggregator form.
/// @dev This implementation does not have any way to verify that the
///      constructor value is correctly denominated in the static 18 decimals
///      format.
///      
///      Tests should be built and ran before/during deployment to verify that
///      the static price configured is correct. This should also be verified
///      separately on chain until any protocol introduces a dependency on
///      this aggregator.
///
abstract contract StaticPriceAggregator is IChainlink {
    /// CONSTANTS ///

    /// @notice The static price to return when pricing an asset, in `WAD`.
    int256 internal immutable _staticPrice;

    /// ERRORS ///

    error StaticPriceAggregator__InvalidConfig();

    /// @param staticPrice The price this Static Price Aggregator
    ///                    will always return.
    constructor(uint256 staticPrice) {
        if (staticPrice == 0) {
            revert StaticPriceAggregator__InvalidConfig();
        }

        // Note: Unsafe cast below is okay because `type(int256).max`
        //       is guaranteed to be positive.
        if (staticPrice > uint256(type(int256).max)) {
            revert StaticPriceAggregator__InvalidConfig();
        }

        _staticPrice = int256(staticPrice);
    }


    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the number of decimals the aggregator responds with.
    /// @return result The number of decimals the aggregator responds with.
    function decimals() external pure override returns (uint8 result) {
        result = 18;
    }

    /// @notice Returns the latest oracle data from the aggregator,
    ///         adjusted by the wrapper.
    /// @return uint80 The round ID from the aggregator for which the data
    ///                was retrieved.
    ///         int256 The price returned by the aggregator, adjusted by
    ///                the wrapper.
    ///         uint256 The timestamp the current round was started.
    ///         uint256 The timestamp the current round last was updated.
    ///         uint80 The round ID of the round in which `answer`
    ///                was computed.
    function latestRoundData() external view override returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (1, _staticPrice, block.timestamp, block.timestamp, 1);
    }

    /// @notice Get the latest round ID.
    /// @return result The latest round ID.
    function latestRound() external pure override returns (uint256 result) {
        result = 1;
    }

    /// @notice Returns the oracle data from the aggregator for a roundId,
    ///         adjusted by the wrapper.
    /// @dev For this implementation it always returns the `_staticPrice`.
    /// @param _roundId The round ID to retrieve data from the aggregator.
    /// @return uint80 The round ID from the aggregator for which the data
    ///                 was retrieved.
    ///         int256 The price returned by the aggregator,
    ///                adjusted by the wrapper.
    ///         uint256 The timestamp the `_roundId` was started.
    ///         uint256 The timestamp the `_roundId` last was updated.
    ///         uint80 The round ID of the round in which `answer`
    ///                         was computed.
    function getRoundData(uint80 _roundId) external view override returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        if (_roundId > 1) {
            return (_roundId, 0, 0, 0, _roundId);
        }
        
        return (_roundId, _staticPrice, block.timestamp, block.timestamp, _roundId);
    }
}