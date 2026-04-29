// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IRedstone } from "contracts/interfaces/external/redstone/IRedstone.sol";

/// @title Curvance Oracle Extractable Value Wrapped Aggregator.
/// @notice Delays oracle updates in specific values to capture value usually
///         leaked by oracle based protocols.
/// @dev Curvance OEV wrapped aggregators are intended to hook up to any
///      onchain push based oracle that supports rounds of data with the
///      "latestRoundData" function interface (see "IChainlink"). A minimum
///      time delay and round traversal amount acts as a floor on the delay
///      allowed to capture OEV, a maximum value for both `MAX_ROUND_DELAY`
///      and `MAX_ROUND_DECREMENTS` MUST be implemented in the smart contract
///      which has the "marketPermissions" role and checked whenever
///      `setConfigValues` is called.
///
///      The typical workflow is that auction based liquidations first update
///      the oracle price via calling `updatePriceEarly` and then execute the
///      liquidation with the updated oracle pricing allowing the liquidation
///      to process successfully.
///
///      These aggregators should then be listed in the corresponding adaptor
///      (e.g. "ChainlinkAdaptor", "RedstoneClassicAdaptor") to price assets
///      inside Curvance Markets.
///
///      NOTE: This should work for nearly all Chainlink aggregators, but,
///            this only works for specific Redstone implements which
///            implement historical rounds, which is not always true, offchain
///            validation must be done before deploying! 
contract OEVWrappedAggregator is IChainlink, IRedstone {
    /// CONSTANTS ///

    /// @notice The maximum value ever allowed for `MAX_ROUND_DELAY` or
    ///         `MAX_ROUND_DECREMENTS` due to data storage size.
    /// @dev NOTE: This should NOT be the only maximum value check performed,
    ///            an additional check should be performed within the risk
    ///            operator smart contract based on the chain and
    ///            corresponding oracle aggregator.
    uint256 public constant MAX_ROUND_VALUE_POSSIBLE = type(uint8).max;
    /// @notice Minimum value for `MAX_ROUND_DELAY`, the maximum delay in time a
    ///         round has before falling back to latest price, in seconds.
    /// @dev 100 = 1 second delay.
    uint256 public constant MIN_DELAY_LIMIT = 1;
        /// @notice Minimum value for `MAX_ROUND_DECREMENTS`, the maximum number of times
    ///         to decrement the roundId before falling back to latest price.
    /// @dev 100 = 1 additional round checked.
    uint256 public constant MIN_DECREMENTS_LIMIT = 1;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @dev Mask of `MAX_ROUND_DELAY` entry in `_aggregatorConfig`.
    uint256 internal constant _BITMASK_MAX_ROUND_DELAY = (1 << 8) - 1;
    /// @dev Mask of round processing entries
    ///      (`MAX_ROUND_DELAY` and `MAX_ROUND_DECREMENTS`) in `_aggregatorConfig`.
    uint256 internal constant _BITMASK_CONFIG = (1 << 16) - 1;
    /// @dev The bit position of `MAX_ROUND_DECREMENTS` in `_aggregatorConfig`.
    uint256 internal constant _BITPOS_MAX_ROUND_DECREMENTS = 8;
    /// @dev The bit position of `ROUND_ID` in `_aggregatorConfig`.
    uint256 internal constant _BITPOS_ROUND_ID = 16;

    /// @notice The address of the underlying asset aggregator.
    IChainlink internal immutable _assetAggregator;
    /// @notice The DataFeedId attached to this aggregator, used inside
    ///         Redstone Classic underlying aggregators.
    bytes32 internal immutable _dataFeedId;

    /// STORAGE ///

    /// @notice The current cached aggregator round and instructions on how
    ///         to process round data.
    /// @dev Bits Layout:
    ///      - [0..7]   `MAX_ROUND_DELAY`.
    ///      - [8..15]  `MAX_ROUND_DECREMENTS`.
    ///      - [16..95] `ROUND_ID`.
    uint256 internal _aggregatorConfig;

    /// EVENTS /// 

    /// @notice Emitted when OEV wrapped aggregator config values are
    ///         changed.
    /// @param oldMaxRoundDelay The old maximum round delay, in seconds.
    /// @param newMaxRoundDelay The new maximum round delay, in seconds.
    /// @param oldMaxDecrements The old maximum number of decrements.
    /// @param newMaxDecrements The new maximum number of decrements.
    event ConfigChanged(
        uint256 oldMaxRoundDelay,
        uint256 newMaxRoundDelay,
        uint256 oldMaxDecrements,
        uint256 newMaxDecrements
    );

    /// ERRORS ///

    error OEVWrappedAggregator__Unauthorized();
    error OEVWrappedAggregator__InvalidConfig();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param aggregator The underlying aggregator to delay updated from
    ///                   to capture OEV.
    /// @param maxRoundDelay The new maximum round delay, in seconds.
    /// @param maxRoundDecrements The new maximum number of rounds to review
    ///                           before defaulting to the latest round.
    constructor(
        ICentralRegistry cr,
        address aggregator,
        uint256 maxRoundDelay,
        uint256 maxRoundDecrements,
        string memory id
    ) {
        CentralRegistryLib._isCentralRegistry(cr);

        (uint256 roundId, int256 answer,,uint256 updatedAt,) =
            IChainlink(aggregator).latestRoundData();
        // This check should basically never fail but its here incase somehow
        // the deployer misconfigured the aggregator address, also doubles as
        // checking that the function call did not fail.
        if (answer <= 0 || updatedAt == 0 || roundId == 0) {
            revert OEVWrappedAggregator__InvalidConfig();
        }

        centralRegistry = cr;
        _assetAggregator = IChainlink(aggregator);
        _dataFeedId = Bytes32Helper.toBytes32(id);

        // We pass 0 for cached _aggregatorConfig since it should be empty
        // at this point.
        _setConfigValues(0, maxRoundDelay, maxRoundDecrements, roundId);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the current cached aggregator configuration.
    /// @return maxRoundDelay The maximum delay in time a round has before
    ///                       falling back to latest price, in seconds.
    /// @return maxRoundDecrements The maximum number of times to decrement
    ///                            the round before falling back to latest
    ///                            price.
    /// @return roundId The last cached roundId to pull price from.
    function getAggregatorInformation() external view returns (
        uint256 maxRoundDelay,
        uint256 maxRoundDecrements,
        uint256 roundId
    ) {
        // Cache `_aggregatorConfig`, the packed cached data storage value.
        uint256 config = _aggregatorConfig;
        maxRoundDelay = uint8(config);
        maxRoundDecrements = uint8(config >> _BITPOS_MAX_ROUND_DECREMENTS);
        roundId = uint80(config >> _BITPOS_ROUND_ID);
    }

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
    /// @dev If the traversal fails to find a round then the wrapped
    ///      aggregator defaults to the latest round data.
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
        uint256 config = _aggregatorConfig;

        // Return the current round data if either:
        // 1. This round has already been cached (meaning someone paid for it).
        // 2. The round is too old.
        if (
            roundId == uint80(config >> _BITPOS_ROUND_ID) /* ROUND_ID */ ||
            block.timestamp >= updatedAt + uint8(config) // MAX_ROUND_DELAY
        ) {
            return (roundId, answer, startedAt, updatedAt, answeredInRound);
        }

        uint256 startRoundId = roundId;

        // If the current round is not too old and has not been paid for,
        // attempt to find the most recent valid round by checking previous
        // rounds.
        uint256 maxRoundDecrements = uint8(config >> _BITPOS_MAX_ROUND_DECREMENTS); 
        for (uint256 i; i < maxRoundDecrements && --startRoundId > 0; ++i) {
            try _assetAggregator.getRoundData(uint80(startRoundId)) returns (
                uint80 r, int256 a, uint256 s, uint256 u, uint80 ar
            ) {
                // Validate this round is safe, otherwise keep looking.
                // Skip via `continue` (not revert) so the loop falls
                // through to the live `latestRoundData` if every
                // historical round in the decrement window is malformed.
                if (a <= 0 || u == 0) {
                    continue;
                }

                roundId = r;
                answer = a;
                startedAt = s;
                updatedAt = u;
                answeredInRound = ar;
                return (roundId, answer, startedAt, updatedAt, answeredInRound);
            } catch {}
        }
    }

    /// @notice Get the latest round ID supported by this wrapped aggregator.
    /// @return result The latest round ID supported by this wrapped
    ///                aggregator.
    function latestRound() external view override returns (uint256 result) {
        result = uint80(_aggregatorConfig >> _BITPOS_ROUND_ID);
    }

    /// @notice Returns the oracle data from the aggregator for `_roundId`.
    /// @param _roundId The round ID to retrieve data from the aggregator.
    /// @return roundId The round ID from the aggregator for which the data
    ///                 was retrieved.
    ///         answer The price returned by the aggregator.
    ///         startedAt The timestamp the `_roundId` was started.
    ///         updatedAt The timestamp the `_roundId` last was updated.
    ///         answeredInRound The round ID of the round in which `answer`
    ///                         was computed.
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        (roundId, answer, startedAt, updatedAt, answeredInRound) =
            _assetAggregator.getRoundData(_roundId);
    }

    /// @notice Returns the DataFeedId of the Redstone price feed, equal to
    ///         address(0) for oracles that do not utilize a data feed ID.
    /// @return result The DataFeedId attached to this aggregator.
    function getDataFeedId() external view returns (bytes32 result) {
        result = _dataFeedId;
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Update the price earlier than the standard update interval
    /// @dev Only callable by whitelisted addresses
    function updatePriceEarly() external {
        _checkAuctionPermissions();

        // Get latest round data and validate it.
        (uint80 latestRoundId, int256 latestAnswer,, uint256 latestUpdatedAt,) =
            _assetAggregator.latestRoundData();
        uint256 config = _aggregatorConfig;

        // Only update if the new round is higher than cached.
        if (latestRoundId > uint80(config >> _BITPOS_ROUND_ID)) {
            // Only approve the update if the round data is safe.
            if (latestAnswer > 0 && latestUpdatedAt > 0) {
                assembly {
                    // Assign packed `_aggregatorConfig` equal to:
                    // Mask `config` to the lower 16 bits, to keep both configuration values.
                    // `Masked `config` | (latestRoundId << _BITPOS_ROUND_ID)`.
                    sstore(
                        _aggregatorConfig.slot, 
                        or(
                            and(config, _BITMASK_CONFIG),
                            shl(_BITPOS_ROUND_ID, latestRoundId)
                        )
                    )
                }
            } 
        }
        // Else gracefully move on without reverting.
        // This allows the off-chain auctioneer to call this function
        // regardless of there being a new price update; and for
        // interest-triggered liquidations to occur via this UserOp path.
    }

    /// @notice Set the configuration values for this wrapped aggregator.
    /// @dev Emits a {ConfigChanged} event.
    /// @param maxRoundDelay The new maximum round delay, in seconds.
    /// @param maxRoundDecrements The new maximum number of rounds to review
    ///                           before defaulting to the latest round.
    function setConfigValues(
        uint256 maxRoundDelay,
        uint256 maxRoundDecrements
    ) external {
        _checkAuctionPermissions();
        _setConfigValues(_aggregatorConfig, maxRoundDelay, maxRoundDecrements, 0);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the underlying aggregator address.
    /// @return r The underlying aggregator address.
    function underlyingAggregator() public view returns (IChainlink r) {
        r = _assetAggregator;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Set the configuration values for this wrapped aggregator.
    /// @dev If `roundId` is 0 we use the current packed config roundId.
    ///      Emits a {ConfigChanged} event.
    /// @param config The current cached `_aggregatorConfig` packed value.
    /// @param maxRoundDelay The new maximum round delay, in seconds.
    /// @param maxRoundDecrements The new maximum number of decrements.
    /// @param roundId The roundId that should be included with the updated
    ///                config values, 0 equal use current packed value.
    function _setConfigValues(
        uint256 config,
        uint256 maxRoundDelay,
        uint256 maxRoundDecrements,
        uint256 roundId
    ) internal {
        if (
            maxRoundDecrements < MIN_DECREMENTS_LIMIT ||
            maxRoundDelay < MIN_DELAY_LIMIT ||
            maxRoundDecrements > MAX_ROUND_VALUE_POSSIBLE ||
            maxRoundDelay > MAX_ROUND_VALUE_POSSIBLE
        ) {
            revert OEVWrappedAggregator__InvalidConfig();
        }

        // If `roundId` is 0 we use the current packed config roundId.
        if (roundId == 0) {
            roundId = uint80(config >> _BITPOS_ROUND_ID);
        }

        uint256 oldMaxRoundDelay = uint8(config);
        uint256 oldMaxRoundDecrements = uint8(config >> _BITPOS_MAX_ROUND_DECREMENTS);

        assembly {
            // Assign packed `_aggregatorConfig` based on config values.
            // Mask `maxRoundDelay` to the lower 8 bits, in case the upper bits
            // somehow are not clean.
            // Equals `Masked maxRoundDelay | (maxRoundDecrements << _BITPOS_MAX_ROUND_DECREMENTS) |
            //         (roundId << _BITPOS_ROUND_ID)`.
            sstore(
                _aggregatorConfig.slot,
                or(
                    and(maxRoundDelay, _BITMASK_MAX_ROUND_DELAY),
                    or(
                        shl(_BITPOS_MAX_ROUND_DECREMENTS, maxRoundDecrements),
                        shl(_BITPOS_ROUND_ID, roundId)
                    )
                )
            )
        }

        emit ConfigChanged(
            oldMaxRoundDelay,
            maxRoundDelay,
            oldMaxRoundDecrements,
            maxRoundDecrements
        );
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkAuctionPermissions() internal view virtual {
        if (!centralRegistry.hasAuctionPermissions(msg.sender)) {
            revert OEVWrappedAggregator__Unauthorized();
        }
    }
}