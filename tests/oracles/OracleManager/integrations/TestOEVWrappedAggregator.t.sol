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
}
