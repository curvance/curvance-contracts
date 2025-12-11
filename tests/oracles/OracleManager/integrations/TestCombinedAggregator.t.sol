// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { BaseWrappedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

contract TestCombinedAggregator is Test {
    string internal constant ASSET_ID = "ezETH/USD";

    CentralRegistry internal centralRegistry;
    CombinedAggregator internal combined;
    IChainlink internal primaryAgg;
    IChainlink internal secondaryAgg;

    function setUp() public {
        // Use a known timestamp
        vm.warp(2_000_000_000);

        // Deploy a minimal CentralRegistry 
        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            block.timestamp + 365 days,
            address(0), // sequencer
            address(0)  // feeToken
        );

        // Primary = ETH/USD at $4000, 
        // secondary = ezETH/ETH at 1.5 ETH per ezETH
        primaryAgg = IChainlink(address(new MockV3Aggregator(8, int256(4000e8))));
        secondaryAgg = IChainlink(address(new MockV3Aggregator(8, int256(1.5e8))));

        // Deploy CombinedAggregator using mock feeds so tests remain stable
        combined = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAgg),
            address(secondaryAgg),
            0, // use DEFAULT_HEARTBEAT for secondary
            ASSET_ID
        );
    }

    function test_combinedAggregator_correctlyCombinesPrices() public {
        (,int256 primaryAnswer,,,) = primaryAgg.latestRoundData();
        (,int256 secondaryAnswer,,,) = secondaryAgg.latestRoundData();

        uint8 secondaryDecimals = secondaryAgg.decimals();
        uint256 scale = 10 ** uint256(secondaryDecimals);

        // (ezETH/ETH) * (ETH/USD) scaled by 10**secondaryDecimals
        uint256 expected = (uint256(primaryAnswer) * uint256(secondaryAnswer)) / scale;

        (,int256 combinedAnswer,, uint256 updatedAt,) = combined.latestRoundData();

        // Check that we received non-stale data
        assertTrue(updatedAt != 0, "unexpected stale updatedAt");

        // Compare answers exactly
        assertEq(uint256(combinedAnswer), expected, "wrong combined price");

        // getAdjustedAnswer(primaryAnswer) should equal the same multiplication
        int256 adjusted = combined.getAdjustedAnswer(primaryAnswer);
        assertEq(uint256(adjusted), expected, "getAdjustedAnswer: mismatch");
    }

    function test_combinedAggregator_decimalsMatchPrimary() public {
        uint8 primaryDecimals = primaryAgg.decimals();
        uint8 combinedDecimals = combined.decimals();
        assertEq(combinedDecimals, primaryDecimals, "decimals mismatch");
    }

    function test_combinedAggregator_staleSecondarySetsUpdatedAtZero() public {

        // Set secondary heartbeat very small so oracle update appears stale
        combined.setSecondaryHeartbeat(1);

        // Advance time so the last secondary update is older than the heartbeat
        skip(2 days);

        (,,,uint256 updatedAt,) = combined.latestRoundData();

        // When secondary is stale, CombinedAggregator bubbles updatedAt = 0
        assertEq(updatedAt, 0, "updatedAt should be zero when secondary is stale");
    }

    function test_combinedAggregator_setSecondaryHeartbeat_fail_invalidHeartbeat() public {
        uint256 HEARTBEAT_GRACE_PERIOD = 120;
        uint256 DEFAULT_HEARTBEAT = 1 days + HEARTBEAT_GRACE_PERIOD;

        // Will fail if heartbeat is greater than DEFAULT_HEARTBEAT
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidHeartbeat.selector);
        uint256 invalidHeartbeat = DEFAULT_HEARTBEAT + 1;
        combined.setSecondaryHeartbeat(invalidHeartbeat);
    }

    function test_combinedAggregator_setSecondaryHeartbeat_success_defaultHeartbeat() public {
        uint256 HEARTBEAT_GRACE_PERIOD = 120;
        uint256 DEFAULT_HEARTBEAT = 1 days + HEARTBEAT_GRACE_PERIOD;
        combined.setSecondaryHeartbeat(0);

        // Ensure the heartbeat is set to DEFAULT_HEARTBEAT
        assertEq(combined.secondaryHeartbeat(), DEFAULT_HEARTBEAT, "secondary heartbeat mismatch");
    }

    function test_combinedAggregator_setSecondaryHeartbeat_success_customHeartbeat() public {
        uint256 HEARTBEAT_GRACE_PERIOD = 120;
        uint256 DEFAULT_HEARTBEAT = 1 days + HEARTBEAT_GRACE_PERIOD;
        uint256 customHeartbeat = 1 hours;
        combined.setSecondaryHeartbeat(customHeartbeat);

        // Ensure the secondary heartbeat is set to the custom heartbeat + HEARTBEAT_GRACE_PERIOD
        // heartbeat = heartbeat != 0 ?
        //    heartbeat + HEARTBEAT_GRACE_PERIOD : DEFAULT_HEARTBEAT;
        assertEq(combined.secondaryHeartbeat(), customHeartbeat + HEARTBEAT_GRACE_PERIOD, "secondary heartbeat mismatch");
    }

    function test_combinedAggregator_constructor_fail_invalidHeartbeat() public {
        uint256 HEARTBEAT_GRACE_PERIOD = 120;
        uint256 DEFAULT_HEARTBEAT = 1 days + HEARTBEAT_GRACE_PERIOD;
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidHeartbeat.selector);
        new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAgg),
            address(secondaryAgg),
            1 days + 1, // right at the edge of default heartbeat
            ASSET_ID
        );
    }

    function test_combinedAggregator_constructor_success_customHeartbeat() public {
        uint256 HEARTBEAT_GRACE_PERIOD = 120;
        uint256 DEFAULT_HEARTBEAT = 1 days + HEARTBEAT_GRACE_PERIOD;
        uint256 customHeartbeat = 1 hours;
        CombinedAggregator combined2 = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAgg),
            address(secondaryAgg),
            customHeartbeat,
            ASSET_ID
        );

        assertEq(combined2.secondaryHeartbeat(), customHeartbeat + HEARTBEAT_GRACE_PERIOD, "secondary heartbeat mismatch");
    }

    function test_combinedAggregator_constructor_success_stateCorrectlySet() public {
        uint256 HEARTBEAT_GRACE_PERIOD = 120;
        uint256 DEFAULT_HEARTBEAT = 1 days + HEARTBEAT_GRACE_PERIOD;
        uint256 customHeartbeat = 1 hours;
        CombinedAggregator combined2 = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAgg),
            address(secondaryAgg),
            customHeartbeat,
            ASSET_ID
        );

        // Check custom heartbeat is set correctly
        assertEq(combined2.secondaryHeartbeat(), customHeartbeat + HEARTBEAT_GRACE_PERIOD, "secondary heartbeat mismatch");
        // Check secondary aggregator is set correctly
        assertEq(address(combined2.secondaryAggregator()), address(secondaryAgg), "secondary aggregator mismatch");
        // Check central registry is set correctly
        assertEq(address(combined2.centralRegistry()), address(centralRegistry), "central registry mismatch");
        // Check underlying aggregator is set correctly
        assertEq(address(combined2.underlyingAggregator()), address(primaryAgg), "underlying aggregator mismatch");
        // Check decimals are set correctly
        assertEq(combined2.decimals(), primaryAgg.decimals(), "decimals mismatch");
        // Check the DataFeedId is set correctly
        // assertEq(combined.getDataFeedId(), ASSET_ID, "data feed id mismatch");
    }

    function test_priceGuard_static_success_clampsSecondaryMax() public {
        // primary = ETH/USD at 4000, secondary = ezETH/ETH at 1.5
        MockV3Aggregator ETH_USDC_Mock = new MockV3Aggregator(8, int256(4000e8)); // ETH/USD
        MockV3Aggregator ezETH_ETH_Mock = new MockV3Aggregator(8, int256(1.5e8)); // 1.5

        CombinedAggregator combined2 = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(ETH_USDC_Mock),
            address(ezETH_ETH_Mock),
            0,
            "MOCK/USD"
        );

        // Configure static guard on secondary
        uint256 basePrice = 1.2e8; // 1.2
        uint256 minPrice = 1e8;    // 1.0
        combined2.setGuardedPriceConfig(
            0, // timestampStart must be 0 for static guard
            0, // ips = 0
            basePrice,
            minPrice
        );

        // Secondary=1.5 and base=1.2, adjusted secondary should clamp to 1.2
        (, int256 answer,,,) = combined2.latestRoundData();

        // expected combined = ETH/USD (4000) * (1.2) = 4800
        assertEq(uint256(answer), 4800e8, "unexpected combined price after clamp");

        // Explicitly check that the getAdjustedAnswer function works correctly
        int256 adjusted = combined2.getAdjustedAnswer(int256(4000e8));
        assertEq(uint256(adjusted), 4800e8, "static guard failed to clamp to base");

        // Push secondary higher (2.0) and verify it is still clamped to 1.2
        ezETH_ETH_Mock.updateAnswer(int256(2e8)); // 2.0
        (, int256 answer2,,,) = combined2.latestRoundData();
        assertEq(uint256(answer2), 4800e8, "combined price should remain clamped after secondary rises");
        int256 adjusted2 = combined2.getAdjustedAnswer(int256(4000e8));
        assertEq(uint256(adjusted2), 4800e8, "clamp not enforced after secondary increase");
    }

    function test_priceGuard_static_success_zeroWhenBelowMin() public {

        MockV3Aggregator ETH_USDC_Mock = new MockV3Aggregator(8, int256(4000e8)); // ETH/USD
        MockV3Aggregator ezETH_ETH_Mock = new MockV3Aggregator(8, int256(1.2e8));   // 1.2

        CombinedAggregator combined2 = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(ETH_USDC_Mock),
            address(ezETH_ETH_Mock),
            0,
            "MOCK/USD"
        );

        uint256 basePrice = 2e8;
        uint256 minPrice = 1e8;
        combined2.setGuardedPriceConfig(
            0,
            0,
            basePrice,
            minPrice
        );

        ezETH_ETH_Mock.updateAnswer(int256(0.5e8)); // 0.5

        // secondary = 0.5 < min of 1.0 soshould return 0
        (, int256 answer,,,) = combined2.latestRoundData();
        assertEq(uint256(answer), 0, "expected combined answer to be zero when below min");
    }

    function test_priceGuard_dynamic_success_increasesMaxOverTimeAndClamps() public {

        MockV3Aggregator ETH_USDC_Mock = new MockV3Aggregator(8, int256(4000e8));
        MockV3Aggregator ezETH_ETH_Mock = new MockV3Aggregator(8, int256(1.5e8));

        CombinedAggregator combined2 = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(ETH_USDC_Mock),
            address(ezETH_ETH_Mock),
            0,
            "MOCK/USD"
        );

        uint256 ips = 1e9;
        uint256 timestampStart = block.timestamp - 8 days;
        uint256 basePrice = 1.5e8; // 1.3, below 1.5 so clamp triggers
        uint256 minPrice = 1e8;    // 1.0
        combined2.setGuardedPriceConfig(
            timestampStart,
            ips,
            basePrice,
            minPrice
        );

        // Compute expected dynamic max
        uint256 timePassed = block.timestamp - timestampStart;
        uint256 dynamicMax = (basePrice * (timePassed * ips + 1e18)) / 1e18;

        int256 adjusted = combined2.getAdjustedAnswer(int256(4000e8));
        uint256 expected = (4000e8 * (1.5e8)) / 1e8;
        assertEq(uint256(adjusted), expected, "dynamic guard failed to clamp");

        // Advance time and verify dynamic max increases again
        skip(3 days);
        // Leave answer the same but update the timestamp
        ezETH_ETH_Mock.updateAnswer(int256(1.5e8));

        timePassed = block.timestamp - timestampStart;
        dynamicMax = (basePrice * (timePassed * ips + 1e18)) / 1e18;
        adjusted = combined2.getAdjustedAnswer(int256(4000e8));
        expected = (4000e8 * (1.5e8)) / 1e8;
        assertEq(uint256(adjusted), expected, "dynamic guard clamp after time advance mismatch");
    }

    function test_priceGuard_setGuardedPriceConfig_fail_sanityChecks() public {

        MockV3Aggregator ETH_USDC_Mock = new MockV3Aggregator(8, int256(4000e8));
        MockV3Aggregator ezETH_ETH_Mock = new MockV3Aggregator(8, int256(1.5e8));

        CombinedAggregator combined2 = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(ETH_USDC_Mock),
            address(ezETH_ETH_Mock),
            0,
            "MOCK/USD"
        );

        // force the secondary answer to zero
        ezETH_ETH_Mock.updateAnswer(0);

        // Expect revert because setGuardedPriceConfig must have > 0 answer
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidConfig.selector);
        combined2.setGuardedPriceConfig(
            block.timestamp - 9 days,
            1,       // ips != 0 to avoid static timestamp rule
            1.2e8,
            1e8
        );
        // bring secondary answer back to 1.5
        ezETH_ETH_Mock.updateAnswer(1.5e8);

        // ips == 0 requires timestampStart == 0
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidTimestamp.selector);
        combined2.setGuardedPriceConfig(
            block.timestamp - 9 days,
            0,
            1.2e8,
            1e8
        );

        // ips != 0 requires timestampStart != 0
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidTimestamp.selector);
        combined2.setGuardedPriceConfig(
            0,
            1,
            1.2e8,
            1e8
        );

        // ips != 0 requires timestampStart <= now and >= 7 days ago
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidTimestamp.selector);
        combined2.setGuardedPriceConfig(
            block.timestamp + 1,
            1,
            1.2e8,
            1e8
        );
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidTimestamp.selector);
        combined2.setGuardedPriceConfig(
            block.timestamp - 1 days,
            1,
            1.2e8,
            1e8
        );

        // ips must fit in uint40
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidConfig.selector);
        combined2.setGuardedPriceConfig(
            block.timestamp - 9 days,
            uint256(type(uint40).max) + 1,
            1.2e8,
            1e8
        );

        // basePrice cannot be 0 and must fit in uint88
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidConfig.selector);
        combined2.setGuardedPriceConfig(
            block.timestamp - 9 days,
            1,
            0,
            1e8
        );
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidConfig.selector);
        combined2.setGuardedPriceConfig(
            block.timestamp - 9 days,
            1,
            uint256(type(uint88).max) + 1,
            1e8
        );

        // minPrice cannot be > basePrice
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidConfig.selector);
        combined2.setGuardedPriceConfig(
            block.timestamp - 9 days,
            1,
            1e8,
            2e8
        );

        // MinPriceAboveCurrentPrice when min > current answer and <= basePrice
        vm.expectRevert(CombinedAggregator.CombinedAggregator__MinPriceAboveCurrentPrice.selector);
        combined2.setGuardedPriceConfig(
            0,
            0,
            3e8,
            2e8 // > 1.5e8 answer
        );

        // Stale secondary
        combined2.setSecondaryHeartbeat(1); // heartbeat very small
        skip(2 days);
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidHeartbeat.selector);
        combined2.setGuardedPriceConfig(
            0,
            0,
            1.2e8,
            1e8
        );

        // Refresh the updateAt timestamp
        ezETH_ETH_Mock.updateAnswer(1.5e8);
        // Reset heartbeat to default
        combined2.setSecondaryHeartbeat(0);

        // set a valid dynamic config
        uint256 timestampStart = block.timestamp - 9 days;
        combined2.setGuardedPriceConfig(
            timestampStart,
            1,
            2e8,
            1e8
        );
        // New timestampStart must not be earlier than existing timestampStart when > 0
        vm.expectRevert(CombinedAggregator.CombinedAggregator__InvalidTimestamp.selector);
        combined2.setGuardedPriceConfig(
            timestampStart - 1 days,
            1,
            2e8,
            1e8
        );
    }

    function test_combinedAggregator_fail_whenSecondaryHasTooManyDecimals() public {
        MockV3Aggregator ETH_USDC_Mock = new MockV3Aggregator(8, int256(4000e8));
        MockV3Aggregator ezETH_ETH_Mock = new MockV3Aggregator(19, int256(1.5e19));
        vm.expectRevert(BaseWrappedAggregator.BaseWrappedAggregator__InvalidConfig.selector);
        new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(ETH_USDC_Mock),
            address(ezETH_ETH_Mock),
            0,
            "MOCK/USD"
        );
    }
}