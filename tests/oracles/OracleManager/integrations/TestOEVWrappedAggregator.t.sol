// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { OEVWrappedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/OEVWrappedAggregator.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract TestOEVWrappedAggregator is Test {
    string internal constant ASSET_ID = "ETH/USD";
    uint256 internal constant DEFAULT_MAX_ROUND_DELAY = 60;
    uint256 internal constant DEFAULT_MAX_ROUND_DECREMENTS = 5;

    CentralRegistry internal centralRegistry;
    MockV3Aggregator internal underlying;

    function setUp() public {
        vm.warp(2_000_000_000);

        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            block.timestamp + 365 days,
            address(0),
            address(0)
        );

        underlying = new MockV3Aggregator(8, int256(4000e8));
    }

    function test_constructor_revertsWhenLatestUpdatedAtIsZero() public {
        // Force `updatedAt = 0` while keeping `roundId` and `answer` valid.
        // This is the exact regression for the inverted polarity fix:
        // pre-fix used `updatedAt > 0` which accepted updatedAt == 0 and
        // rejected the happy path.
        underlying.updateRoundData(
            uint80(1),
            int256(4000e8),
            0, // _timestamp -> updatedAt
            block.timestamp
        );

        vm.expectRevert(
            OEVWrappedAggregator.OEVWrappedAggregator__InvalidConfig.selector
        );
        new OEVWrappedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(underlying),
            DEFAULT_MAX_ROUND_DELAY,
            DEFAULT_MAX_ROUND_DECREMENTS,
            ASSET_ID
        );
    }

    function test_constructor_revertsWhenLatestRoundIdIsZero() public {
        underlying.updateRoundData(
            uint80(0),
            int256(4000e8),
            block.timestamp,
            block.timestamp
        );

        vm.expectRevert(
            OEVWrappedAggregator.OEVWrappedAggregator__InvalidConfig.selector
        );
        new OEVWrappedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(underlying),
            DEFAULT_MAX_ROUND_DELAY,
            DEFAULT_MAX_ROUND_DECREMENTS,
            ASSET_ID
        );
    }

    function test_constructor_revertsWhenLatestAnswerIsZero() public {
        underlying.updateRoundData(
            uint80(1),
            int256(0),
            block.timestamp,
            block.timestamp
        );

        vm.expectRevert(
            OEVWrappedAggregator.OEVWrappedAggregator__InvalidConfig.selector
        );
        new OEVWrappedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(underlying),
            DEFAULT_MAX_ROUND_DELAY,
            DEFAULT_MAX_ROUND_DECREMENTS,
            ASSET_ID
        );
    }

    function test_constructor_revertsWhenLatestAnswerIsNegative() public {
        underlying.updateRoundData(
            uint80(1),
            int256(-1),
            block.timestamp,
            block.timestamp
        );

        vm.expectRevert(
            OEVWrappedAggregator.OEVWrappedAggregator__InvalidConfig.selector
        );
        new OEVWrappedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(underlying),
            DEFAULT_MAX_ROUND_DELAY,
            DEFAULT_MAX_ROUND_DECREMENTS,
            ASSET_ID
        );
    }

    function test_constructor_acceptsValidLatestRoundData() public {
        // Sanity regression: the post-fix happy path. Pre-fix the inverted
        // `updatedAt > 0` check would have rejected this construction, so
        // the same invocation that powers production deployments must work.
        OEVWrappedAggregator wrapper = new OEVWrappedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(underlying),
            DEFAULT_MAX_ROUND_DELAY,
            DEFAULT_MAX_ROUND_DECREMENTS,
            ASSET_ID
        );

        assertEq(
            address(wrapper.underlyingAggregator()),
            address(underlying),
            "expected wrapper to wire the underlying aggregator"
        );

        (
            uint256 maxRoundDelay,
            uint256 maxRoundDecrements,
            uint256 roundId
        ) = wrapper.getAggregatorInformation();

        assertEq(
            maxRoundDelay,
            DEFAULT_MAX_ROUND_DELAY,
            "expected configured max round delay"
        );
        assertEq(
            maxRoundDecrements,
            DEFAULT_MAX_ROUND_DECREMENTS,
            "expected configured max round decrements"
        );
        assertEq(roundId, 1, "expected initial cached roundId");
    }

    /// @notice Pre-fix: inner `revert` in the try-success-block propagated
    ///         past `catch {}`, DoSing every price read. Post-fix: malformed
    ///         historical rounds (`updatedAt == 0`) are skipped via `continue`.
    function test_latestRoundData_skipsHistoricalRoundWithUpdatedAtZero()
        public
    {
        OEVWrappedAggregator wrapper = _deployWrapper();

        // Round 1 valid (cached). Round 2 malformed (updatedAt=0). Round 3 valid latest.
        underlying.updateRoundData(uint80(2), int256(3000e8), 0, block.timestamp);
        underlying.updateRoundData(uint80(3), int256(4500e8), block.timestamp, block.timestamp);

        // Decrement walks 3 → 2 (skip) → 1 (return).
        (uint80 roundId, int256 answer, , uint256 updatedAt, ) =
            wrapper.latestRoundData();

        assertEq(roundId, uint80(1), "expected fall-back to earlier valid round");
        assertEq(answer, int256(4000e8), "expected answer from valid round 1");
        assertGt(updatedAt, 0, "expected non-zero updatedAt from valid round");
    }

    /// @notice Sibling regression: same fix mechanism for `answer <= 0`
    ///         (other half of the `if (a <= 0 || u == 0)` predicate).
    function test_latestRoundData_skipsHistoricalRoundWithNonPositiveAnswer()
        public
    {
        OEVWrappedAggregator wrapper = _deployWrapper();

        underlying.updateRoundData(uint80(2), int256(-1), block.timestamp, block.timestamp);
        underlying.updateRoundData(uint80(3), int256(4500e8), block.timestamp, block.timestamp);

        (uint80 roundId, int256 answer, , , ) = wrapper.latestRoundData();

        assertEq(roundId, uint80(1), "expected fall-back to earlier valid round");
        assertEq(answer, int256(4000e8), "expected answer from valid round 1");
    }

    /// @notice When every round in the decrement window is malformed,
    ///         fall through to live latest per the natspec contract
    ///         ("defaults to the latest round data"). Pre-fix the first
    ///         malformed round would have reverted.
    function test_latestRoundData_fallsThroughToLiveWhenAllHistoryMalformed()
        public
    {
        OEVWrappedAggregator wrapper = _deployWrapper();

        // Rounds 1-3 each malformed differently; round 4 is the valid live.
        underlying.updateRoundData(uint80(1), int256(0), 0, 0);
        underlying.updateRoundData(uint80(2), int256(-1), block.timestamp, block.timestamp);
        underlying.updateRoundData(uint80(3), int256(2000e8), 0, block.timestamp);
        underlying.updateRoundData(uint80(4), int256(4500e8), block.timestamp, block.timestamp);

        // Loop walks 4 → 3 → 2 → 1 (all skipped), exits, falls through to live.
        (uint80 roundId, int256 answer, , uint256 updatedAt, ) =
            wrapper.latestRoundData();

        assertEq(roundId, uint80(4), "expected fall-through to live latestRoundData");
        assertEq(answer, int256(4500e8), "expected live answer from round 4");
        assertEq(updatedAt, block.timestamp, "expected live updatedAt from round 4");
    }

    /// @notice Existing protection: `maxRoundDecrements = 0` would
    ///         silently disable OEV traversal. The constructor enforces
    ///         `MIN_DECREMENTS_LIMIT (=1)` to prevent this misconfig. Pin
    ///         the rejection so a future loosening of the bound surfaces
    ///         immediately.
    function test_constructor_revertsOnZeroMaxDecrements() public {
        vm.expectRevert(
            OEVWrappedAggregator.OEVWrappedAggregator__InvalidConfig.selector
        );
        new OEVWrappedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(underlying),
            DEFAULT_MAX_ROUND_DELAY,
            0,
            ASSET_ID
        );
    }

    /// @notice Sibling check: `maxRoundDelay = 0` is also rejected.
    function test_constructor_revertsOnZeroMaxRoundDelay() public {
        vm.expectRevert(
            OEVWrappedAggregator.OEVWrappedAggregator__InvalidConfig.selector
        );
        new OEVWrappedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(underlying),
            0,
            DEFAULT_MAX_ROUND_DECREMENTS,
            ASSET_ID
        );
    }

    /// INTERNAL HELPERS ///

    function _deployWrapper() internal returns (OEVWrappedAggregator) {
        return new OEVWrappedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(underlying),
            DEFAULT_MAX_ROUND_DELAY,
            DEFAULT_MAX_ROUND_DECREMENTS,
            ASSET_ID
        );
    }
}
