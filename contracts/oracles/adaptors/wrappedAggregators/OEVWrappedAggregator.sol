// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";

/// @title Curvance Oracle Extractable Value Wrapped Aggregator.
/// @notice Delays oracle updates in specific values to capture value usually
///         leaked by oracle based protocols.
/// @dev Curvance OEV wrapped aggregators are intended to hook up to any
///      onchain push based oracle that supports rounds of data with the
///      "latestRoundData" function interface (see "IChainlink"). A minimum
///      time delay and round traversal amount acts as a floor on the delay
///      allowed to capture OEV, a maximum value for both `maxRoundDelay`
///      and `maxDecrements` MUST be implemented in the smart contract which
///      has the "marketPermissions" role and checked whenever
///      `setMaxRoundDecrements` and `setMaxRoundDelay` is called.
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
contract OEVWrappedAggregator is IChainlink {
    /// CONSTANTS ///

    /// @notice Minimum value for `maxDecrements`, the maximum number of times
    ///         to decrement the roundId before falling back to latest price.
    /// @dev 100 = 1.0%.
    uint256 public constant MIN_DECREMENTS_LIMIT = 1;

    /// @notice Minimum value for `maxRoundDelay`, the maximum delay in time a
    ///         round has before falling back to latest price, in seconds.
    /// @dev 100 = 1.0%.
    uint256 public constant MIN_DELAY_LIMIT = 1;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice The address of the underlying asset aggregator.
    IChainlink internal immutable _assetAggregator;
    /// @notice The oracle adaptor type, calculated via keccak256 of the
    ///         oracle adaptor's name.
    uint256 internal immutable _adaptorType =
        uint256(keccak256(abi.encode("OEVWrappedAggregator")));

    /// STORAGE ///

    /// @notice The maximum number of times to decrement the round before
    ///         falling back to latest price.
    uint256 public maxRoundDecrements;

    /// @notice The maximum delay in time a round has before falling back to
    ///         latest price, in seconds.
    uint256 public maxRoundDelay;

    /// @notice The last cached roundId to pull price from.
    uint256 public cachedRoundId;

    /// EVENTS /// 

    /// @notice Emitted when the max decrements value is changed.
    /// @param oldMaxDecrements The old maximum number of decrements.
    /// @param newMaxDecrements The new maximum number of decrements.
    event MaxRoundDecrementsChanged(uint256 oldMaxDecrements, uint256 newMaxDecrements);

    /// @notice Emitted when the max round delay is changed.
    /// @param oldMaxRoundDelay The old maximum round delay, in seconds.
    /// @param newMaxRoundDelay The new maximum round delay, in seconds.
    event NewMaxRoundDelay(uint256 oldMaxRoundDelay, uint256 newMaxRoundDelay);

    /// ERRORS ///

    error OEVWrappedAggregator__Unauthorized();
    error OEVWrappedAggregator__InvalidConfig();
    error OEVWrappedAggregator__InvalidRoundData();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    constructor(
        ICentralRegistry cr,
        address _aggregator,
        uint256 _maxRoundDecrements,
        uint256 _maxRoundDelay
    ) {
        CentralRegistryLib._isCentralRegistry(cr);
        if (
            _maxRoundDecrements < MIN_DECREMENTS_LIMIT ||
            _maxRoundDelay < MIN_DELAY_LIMIT
        ) {
            revert OEVWrappedAggregator__InvalidConfig();
        }

        // Validate we properly get a price from underlying aggregator, both
        // that the function call did not revert but also we didnt get a 0 or
        // negative value.
        (, int256 answer,,,) = IChainlink(_aggregator).latestRoundData();
        if (answer <= 0) {
            revert OEVWrappedAggregator__InvalidConfig();
        }

        centralRegistry = cr;
        maxRoundDecrements =  _maxRoundDecrements;
        maxRoundDelay = _maxRoundDelay;
        _assetAggregator = IChainlink(_aggregator);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the number of decimals the aggregator responds with.
    /// @return result The number of decimals the aggregator responds with.
    function decimals() external view returns (uint8 result) {
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

        // Return the current round data if either:
        // 1. This round has already been cached (meaning someone paid for it).
        // 2. The round is too old.
        if (roundId == cachedRoundId || block.timestamp >= updatedAt + maxRoundDelay) {
            return (roundId, answer, startedAt, updatedAt, answeredInRound);
        }

        uint256 startRoundId = roundId;

        // If the current round is not too old and has not been paid for,
        // attempt to find the most recent valid round by checking previous
        // rounds.
        for (uint256 i; i < maxRoundDecrements && --startRoundId > 0; ++i) {
            try _assetAggregator.getRoundData(uint80(startRoundId)) returns (
                uint80 r, int256 a, uint256 s, uint256 u, uint80 ar
            ) {
                // Validate this round is safe, otherwise can keep looking.
                if (a <= 0 || u == 0) {
                    revert OEVWrappedAggregator__InvalidRoundData();
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

    /// @notice Get the latest round ID.
    /// @return result The latest round ID.
    function latestRound() external view override returns (uint256 result) {
        result = _assetAggregator.latestRound();
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

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return result The adaptor's type.
    function adaptorType() external view returns (uint256 result) {
        result = _adaptorType;
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Update the price earlier than the standard update interval
    /// @dev Only callable by whitelisted addresses
    function updatePriceEarly() external {
        _checkMarketPermissions();

        // Get latest round data and validate it.
        (uint256 latestRoundId, int256 latestAnswer,, uint256 latestUpdatedAt,) =
            _assetAggregator.latestRoundData();

        // Only update if the new round is higher than cached.
        if (latestRoundId > cachedRoundId) {
            // Only approve the update if the round data is safe.
            if (latestAnswer > 0 && latestUpdatedAt > 0) {
                cachedRoundId = latestRoundId;
            } 
        }
        // Else gracefully move on without reverting.
        // This allows the off-chain auctioneer to call this function
        // regardless of there being a new price update; and for
        // interest-triggered liquidations to occur via this UserOp path.
    }

    /// @notice Set the maximum number of rounds checked before falling back
    ///         to latest price.
    /// @dev Emits a {MaxRoundDecrementsChanged} event.
    /// @param _maxRoundDecrements The new maximum number of decrements.
    function setMaxRoundDecrements(uint256 _maxRoundDecrements) external {
        if (_maxRoundDecrements < MIN_DECREMENTS_LIMIT) {
            revert OEVWrappedAggregator__InvalidConfig();
        }
        _checkMarketPermissions();

        uint256 oldMaxRoundDecrements = _maxRoundDecrements;
        maxRoundDecrements = _maxRoundDecrements;

        emit MaxRoundDecrementsChanged(
            oldMaxRoundDecrements,
            _maxRoundDecrements
        );
    }

    /// @notice Set the maximum delay before price defaults to next round.
    /// @dev Emits a {NewMaxRoundDelay} event.
    /// @param _maxRoundDelay The new maximum round delay, in seconds.
    function setMaxRoundDelay(uint256 _maxRoundDelay) external {
        if (_maxRoundDelay < MIN_DELAY_LIMIT) {
            revert OEVWrappedAggregator__InvalidConfig();
        }
        _checkMarketPermissions();

        uint256 oldMaxRoundDelay = maxRoundDelay;
        maxRoundDelay = _maxRoundDelay;

        emit NewMaxRoundDelay(oldMaxRoundDelay, maxRoundDelay);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the underlying aggregator address.
    /// @return r The underlying aggregator address.
    function underlyingAggregator() public view returns (IChainlink r) {
        r = _assetAggregator;
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkMarketPermissions() internal view virtual {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            revert OEVWrappedAggregator__Unauthorized();
        }
    }
}