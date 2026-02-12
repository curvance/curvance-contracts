// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";

/// @notice Tests for ProtocolManager.setGuardedPriceConfigCombined
/// @dev Tests the CombinedAggregator-specific price guard configuration.
///      CombinedAggregators have a single global PriceGuard (not per-asset).
///      The function validates that the aggregator is correctly mapped to asset+inUSD.
contract TestProtocolManagerSetGuardedPriceConfigCombined is TestProtocolManagerBase {

    CombinedAggregator public combinedAggregator;
    MockV3Aggregator public primaryAggregator;
    MockV3Aggregator public secondaryAggregator;
    address public testAsset;
    address public manager;

    uint256 internal constant MINIMUM_TIMESTAMP_BUFFER = 7 days;

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");
        testAsset = _USDC_ADDRESS;

        // Deploy mock aggregators for primary and secondary feeds
        // Primary: e.g., ETH/USD price ($2000)
        primaryAggregator = new MockV3Aggregator(8, 2000e8);
        // Secondary: e.g., stETH/ETH ratio (1.05)
        secondaryAggregator = new MockV3Aggregator(18, 1.05e18);

        // Deploy CombinedAggregator
        combinedAggregator = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAggregator),
            address(secondaryAggregator),
            0, // Use default heartbeat
            "stETH/USD"
        );

        // Deploy a fresh ChainlinkAdaptor that uses the CombinedAggregator
        chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        // Add CombinedAggregator as the aggregator for testAsset in the adaptor
        chainlinkAdaptor.addAsset(testAsset, true, address(combinedAggregator), 0);

        // Get the old adaptor and replace it
        address[] memory oldAdaptors = oracleManager.getPricingAdaptors(testAsset);
        oracleManager.replaceAssetPricingAdaptor(
            testAsset,
            oldAdaptors[0],
            address(chainlinkAdaptor),
            100, 50, 100, 50
        );

        // Deploy ProtocolManager with manager and managed addresses
        // Need authority over: CombinedAggregator and the asset
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(combinedAggregator);
        managedAddresses[1] = testAsset;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            permsConfig,
            managedAddresses,
            limits
        );

        // Grant ProtocolManager market permissions so it can call setGuardedPriceConfig
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful setGuardedPriceConfigCombined with static price guard (ips = 0)
    function test_setGuardedPriceConfigCombined_success_staticPriceGuard() public {
        // Set up existing price guard on combined aggregator
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;

        combinedAggregator.setGuardedPriceConfig(
            0,
            0,
            existingBasePrice,
            existingMinPrice
        );

        // Manager adjusts within period limits
        uint256 newBasePrice = existingBasePrice + 0.05e18;
        uint256 newMinPrice = existingMinPrice + 0.02e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,           // inUSD
            0,              // timestampStart
            0,              // ips (static mode)
            newBasePrice,
            newMinPrice
        );

        // Verify the price guard was set
        (uint40 pgTimestampStart, uint40 pgIps, uint88 pgBasePrice, uint88 pgMinPrice) =
            combinedAggregator.pg();

        assertEq(pgTimestampStart, 0, "timestampStart should be 0");
        assertEq(pgIps, 0, "ips should be 0");
        assertEq(pgBasePrice, newBasePrice, "basePrice mismatch");
        assertEq(pgMinPrice, newMinPrice, "minPrice mismatch");
    }

    /// @notice Test successful setGuardedPriceConfigCombined with dynamic price guard (ips > 0)
    function test_setGuardedPriceConfigCombined_success_dynamicPriceGuard() public {
        // Set up existing dynamic price guard
        uint256 existingTimestampStart = block.timestamp - MINIMUM_TIMESTAMP_BUFFER - 1;
        uint256 existingIps = 1e10;
        uint256 existingBasePrice = 1.05e18;
        uint256 existingMinPrice = 1.0e18;

        combinedAggregator.setGuardedPriceConfig(
            existingTimestampStart,
            existingIps,
            existingBasePrice,
            existingMinPrice
        );

        // Manager adjusts within period limits
        uint256 newBasePrice = existingBasePrice + 0.03e18;
        uint256 newMinPrice = existingMinPrice + 0.01e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            existingTimestampStart,
            existingIps,
            newBasePrice,
            newMinPrice
        );

        // Verify the price guard was set
        (uint40 pgTimestampStart, uint40 pgIps, uint88 pgBasePrice, uint88 pgMinPrice) =
            combinedAggregator.pg();

        assertEq(pgTimestampStart, existingTimestampStart, "timestampStart mismatch");
        assertEq(pgIps, existingIps, "ips mismatch");
        assertEq(pgBasePrice, newBasePrice, "basePrice mismatch");
        assertEq(pgMinPrice, newMinPrice, "minPrice mismatch");
    }

    /// @notice Test setGuardedPriceConfigCombined for native token pricing (inUSD = false)
    function test_setGuardedPriceConfigCombined_success_nativeTokenPricing() public {
        // Add native token pricing configuration to adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(combinedAggregator), 0);

        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;

        combinedAggregator.setGuardedPriceConfig(
            0,
            0,
            existingBasePrice,
            existingMinPrice
        );

        // Manager adjusts for native pricing
        uint256 newBasePrice = existingBasePrice + 0.05e18;
        uint256 newMinPrice = existingMinPrice + 0.02e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            false,  // inUSD = false (native token)
            0,
            0,
            newBasePrice,
            newMinPrice
        );

        // Verify the price guard was set
        (,, uint88 pgBasePrice, uint88 pgMinPrice) = combinedAggregator.pg();
        assertEq(pgBasePrice, newBasePrice, "basePrice mismatch");
        assertEq(pgMinPrice, newMinPrice, "minPrice mismatch");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setGuardedPriceConfigCombined
    function test_setGuardedPriceConfigCombined_fail_notCurator() public {
        // Set up existing price guard
        combinedAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            1.15e18,
            1.02e18
        );
    }

    /// @notice Test that manager cannot manage aggregator without authority
    function test_setGuardedPriceConfigCombined_fail_aggregatorNoAuthority() public {
        // Deploy a new CombinedAggregator without authority
        CombinedAggregator unauthorizedAgg = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAggregator),
            address(secondaryAggregator),
            0,
            "unauthorized"
        );

        // Set up price guard
        unauthorizedAgg.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setGuardedPriceConfigCombined(
            address(unauthorizedAgg),
            testAsset,
            true,
            0,
            0,
            1.15e18,
            1.02e18
        );
    }

    /// @notice Test that manager cannot configure asset without authority
    function test_setGuardedPriceConfigCombined_fail_assetNoAuthority() public {
        address unauthorizedAsset = makeAddr("unauthorizedAsset");

        // Set up price guard
        combinedAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            unauthorizedAsset,
            true,
            0,
            0,
            1.15e18,
            1.02e18
        );
    }

    /// @notice Test that wrong aggregator for asset+inUSD fails
    function test_setGuardedPriceConfigCombined_fail_wrongAggregatorMapping() public {
        // Deploy another CombinedAggregator that IS authorized but NOT mapped to the asset
        CombinedAggregator otherAggregator = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAggregator),
            address(secondaryAggregator),
            0,
            "other"
        );

        // Set up price guard on the other aggregator
        otherAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        // Create new ProtocolManager with authority over the other aggregator
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(otherAggregator);
        managedAddresses[1] = testAsset;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager pm = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            _getDefaultPermsConfig(),
            managedAddresses,
            limits
        );
        centralRegistry.addMarketPermissions(address(pm));

        // Should fail because otherAggregator is not mapped to testAsset+inUSD in the adaptor
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        pm.setGuardedPriceConfigCombined(
            address(otherAggregator),
            testAsset,
            true,
            0,
            0,
            1.15e18,
            1.02e18
        );
    }

    /// @notice Test that wrong inUSD value fails (aggregator mapped to USD but called with native)
    function test_setGuardedPriceConfigCombined_fail_wrongInUSDMapping() public {
        // combinedAggregator is only mapped for inUSD=true, not inUSD=false
        // Set up price guard
        combinedAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        vm.prank(manager);
        vm.expectRevert(); // Will revert because assetConfig[asset][false] returns different aggregator
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            false,  // Wrong - aggregator is mapped for inUSD=true
            0,
            0,
            1.15e18,
            1.02e18
        );
    }

    /// @notice Test that changing timestampStart from current value reverts
    function test_setGuardedPriceConfigCombined_fail_timestampStartMismatch() public {
        // Set up existing price guard with timestampStart = 0
        combinedAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            block.timestamp - 10 days,  // Different from current (0)
            0,
            1.15e18,
            1.02e18
        );
    }

    /// @notice Test that changing ips from current value reverts
    function test_setGuardedPriceConfigCombined_fail_ipsMismatch() public {
        // Set up existing price guard with ips = 0
        combinedAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            1e10,  // Different from current (0)
            1.15e18,
            1.02e18
        );
    }

    /// PERIOD ADJUSTMENT TESTS ///

    /// @notice Test that basePriceUSD adjustment is tracked correctly
    function test_setGuardedPriceConfigCombined_success_trackBasePriceUSDAdjustment() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // Manager adjusts
        uint256 newBasePrice = existingBasePrice + 0.05e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            existingMinPrice
        );

        // Verify adjustment tracked as delta
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int96 basePriceUSDAdj,,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,
            periodTimestamp
        );

        int256 expectedAdj = int256(newBasePrice) - int256(existingBasePrice);
        assertEq(basePriceUSDAdj, int96(expectedAdj), "basePriceUSD adjustment mismatch");
    }

    /// @notice Test that minPriceUSD adjustment is tracked correctly
    function test_setGuardedPriceConfigCombined_success_trackMinPriceUSDAdjustment() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // Manager adjusts
        uint256 newMinPrice = existingMinPrice + 0.02e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            existingBasePrice,
            newMinPrice
        );

        // Verify adjustment tracked as delta
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (, int96 minPriceUSDAdj,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,
            periodTimestamp
        );

        int256 expectedAdj = int256(newMinPrice) - int256(existingMinPrice);
        assertEq(minPriceUSDAdj, int96(expectedAdj), "minPriceUSD adjustment mismatch");
    }

    /// @notice Test that basePriceNative adjustment is tracked correctly
    function test_setGuardedPriceConfigCombined_success_trackBasePriceNativeAdjustment() public {
        // Add native token pricing
        chainlinkAdaptor.addAsset(testAsset, false, address(combinedAggregator), 0);

        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // Manager adjusts
        uint256 newBasePrice = existingBasePrice + 0.05e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            false,  // native
            0,
            0,
            newBasePrice,
            existingMinPrice
        );

        // Verify adjustment tracked as delta
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,, int96 basePriceNativeAdj,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,
            periodTimestamp
        );

        int256 expectedAdj = int256(newBasePrice) - int256(existingBasePrice);
        assertEq(basePriceNativeAdj, int96(expectedAdj), "basePriceNative adjustment mismatch");
    }

    /// @notice Test that basePriceUSD adjustment exceeding limit reverts
    function test_setGuardedPriceConfigCombined_fail_basePriceUSDLimitExceeded() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // Try to adjust beyond the limit (1e17)
        uint256 newBasePrice = existingBasePrice + 1e17 + 1;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            existingMinPrice
        );
    }

    /// @notice Test that minPriceUSD adjustment exceeding limit reverts
    function test_setGuardedPriceConfigCombined_fail_minPriceUSDLimitExceeded() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // Try to adjust beyond the limit (1e17)
        uint256 newMinPrice = existingMinPrice + 1e17 + 1;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            existingBasePrice,
            newMinPrice
        );
    }

    /// @notice Test cumulative adjustments within period
    function test_setGuardedPriceConfigCombined_success_cumulativeAdjustments() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // First update
        uint256 basePrice1 = existingBasePrice + 0.02e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            basePrice1,
            existingMinPrice
        );

        // Second update
        uint256 basePrice2 = basePrice1 + 0.02e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            basePrice2,
            existingMinPrice
        );

        // Verify cumulative adjustment
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int96 basePriceUSDAdj,,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,
            periodTimestamp
        );

        int256 expectedAdj = int256(basePrice2) - int256(existingBasePrice);
        assertEq(basePriceUSDAdj, int96(expectedAdj), "cumulative adjustment mismatch");
    }

    /// @notice Test that cumulative adjustments exceeding limit reverts
    function test_setGuardedPriceConfigCombined_fail_cumulativeUpdateExceedsLimit() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // First update: increase by 0.05e18 (within limit)
        uint256 basePrice1 = existingBasePrice + 0.05e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            basePrice1,
            existingMinPrice
        );

        // Second update: try to increase beyond cumulative limit
        uint256 basePrice2 = basePrice1 + 0.06e18;  // Total 0.11e18 > 0.1e18 limit

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            basePrice2,
            existingMinPrice
        );
    }

    /// @notice Test that adjustments reset after period ends
    function test_setGuardedPriceConfigCombined_success_adjustmentsResetAfterPeriod() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // First update in current period
        uint256 basePrice1 = existingBasePrice + 0.05e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            basePrice1,
            existingMinPrice
        );

        // Warp forward past the period duration (1 week)
        vm.warp(block.timestamp + 604800 + 1);

        // Update mock oracles to avoid stale data errors
        primaryAggregator.updateAnswer(2000e8);
        secondaryAggregator.updateAnswer(1.05e18);

        // In new period, adjustment resets
        uint256 basePrice2 = basePrice1 + 0.05e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true,
            0,
            0,
            basePrice2,
            existingMinPrice
        );

        // Verify new period has fresh adjustment
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int96 adj,,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,
            periodTimestamp
        );

        int256 expectedAdj = int256(basePrice2) - int256(basePrice1);
        assertEq(adj, int96(expectedAdj), "New period should track delta from period start value");
    }
}
