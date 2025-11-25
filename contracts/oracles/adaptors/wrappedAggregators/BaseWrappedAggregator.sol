// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { WAD } from "contracts/libraries/ConstantsLib.sol";
import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IRedstone } from "contracts/interfaces/external/redstone/IRedstone.sol";

/// @title Curvance Base Wrapped Aggregator.
/// @notice Modifies an oracle aggregator to return the price for a different
///         asset, based on the exchange rate between them.
/// @dev Curvance wrapped aggregators are intended to hook up to any
///      onchain push based oracle that supports rounds of data with the
///      "latestRoundData" function interface (see "IChainlink"). An exchange
///      rate between the oracle aggregator's asset and the wrapped
///      aggregator's asset is calculated and applied to the underlying
///      aggregator's answer.
///
///      Validation is done on contract deployment to ensure that the linked
///      contracts have the expected asset addresses supported and that any
///      difference in decimals between the assets MUST be adjusted so that
///      the new answer's decimals batches the underlying aggregator's
///      decimals.
///
///      These child contract aggregators should then be listed in the
///      corresponding adaptor (e.g. "ChainlinkAdaptor",
///      "RedstoneClassicAdaptor") to price assets inside Curvance Markets.
///
abstract contract BaseWrappedAggregator is IChainlink, IRedstone {
    /// CONSTANTS ///

    /// @notice The address of the underlying asset aggregator.
    IChainlink internal immutable _assetAggregator;
    /// @notice The DataFeedId attached to this aggregator, used inside
    ///         Redstone Classic underlying aggregators.
    bytes32 internal immutable _dataFeedId;

    /// ERRORS ///

    error BaseWrappedAggregator__InvalidConfig();
    error BaseWrappedAggregator__UintToIntError();

    /// @param aggregator The underlying aggregator to wrap additional logic
    ///                   around to price a different asset.
    /// @param id The dataFeedId of the token to add pricing for.
    constructor(address aggregator, string memory id) {
        (uint256 roundId, int256 answer,,uint256 updatedAt,) =
            IChainlink(aggregator).latestRoundData();
        // This check should basically never fail but its here incase somehow
        // the deployer misconfigured the aggregator address, also doubles as
        // checking that the function call did not fail.
        if (answer <= 0 || updatedAt == 0 || roundId == 0) {
            revert BaseWrappedAggregator__InvalidConfig();
        }

        _assetAggregator = IChainlink(aggregator);
        _dataFeedId = Bytes32Helper.toBytes32(id);
    }


    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the number of decimals the aggregator responds with.
    /// @return result The number of decimals the aggregator responds with.
    function decimals() external view override (
        IChainlink,
        IRedstone
    ) returns (uint8 result) {
        result = _assetAggregator.decimals();
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
        virtual
        override (IChainlink, IRedstone)
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

        answer = getAdjustedAnswer(answer);
    }

    /// @notice Get the latest round ID.
    /// @return result The latest round ID.
    function latestRound() external view override returns (uint256 result) {
        result = _assetAggregator.latestRound();
    }

    /// @notice Returns the oracle data from the aggregator for `_roundId`,
    ///         adjusted by the wrapper.
    /// @param _roundId The round ID to retrieve data from the aggregator.
    /// @return roundId The round ID from the aggregator for which the data
    ///                 was retrieved.
    ///         answer The price returned by the aggregator,
    ///                adjusted by the wrapper.
    ///         startedAt The timestamp the `_roundId` was started.
    ///         updatedAt The timestamp the `_roundId` last was updated.
    ///         answeredInRound The round ID of the round in which `answer`
    ///                         was computed.
    function getRoundData(uint80 _roundId)
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
        (roundId, answer, startedAt, updatedAt, answeredInRound) =
            _assetAggregator.getRoundData(_roundId);

        answer = getAdjustedAnswer(answer);
    }

    /// @notice Returns the DataFeedId of the Redstone price feed, equal to
    ///         address(0) for oracles that do not utilize a data feed ID.
    /// @return result The DataFeedId attached to this aggregator.
    function getDataFeedId() external view returns (bytes32 result) {
        result = _dataFeedId;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the underlying aggregator address.
    /// @return result The underlying aggregator address.
    function underlyingAggregator() public view returns (IChainlink result) {
        result = _assetAggregator;
    }

    /// PUBLIC FUNCTIONS TO OVERRIDE ///

    /// @notice Returns the adjusted `answer` based on the current exchange
    ///         rate between the wrapped asset and the underlying aggregator.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @return The adjusted oracle `answer`.
    function getAdjustedAnswer(int256) public view virtual returns (int256);

    /// INTERNAL FUNCTIONS ///

    /// @notice Converts an unsigned uint256 into a signed int256.
    /// @param value The uint256 value to convert to int256.
    /// @return result The converted int256 value.
    function _toInt256(uint256 value) internal pure returns (int256 result) {
        // Note: Unsafe cast below is okay because `type(int256).max`
        //       is guaranteed to be positive
        if (value > uint256(type(int256).max)) {
            revert BaseWrappedAggregator__UintToIntError();
        }

        result = int256(value);
    }
}