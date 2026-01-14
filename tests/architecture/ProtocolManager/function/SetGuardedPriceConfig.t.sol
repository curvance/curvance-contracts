// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.setGuardedPriceConfig
/// @dev The manager (protocolManager address) calls setGuardedPriceConfig to set price guards
///      on oracle adaptors. Both the adaptor and asset must have authority in the config.
contract TestProtocolManagerSetGuardedPriceConfig is TestProtocolManagerBase {

    MockV3Aggregator public mockAggregator;
    address public testAsset;
    address public manager;

    uint256 internal constant MINIMUM_TIMESTAMP_BUFFER = 7 days;

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");
        testAsset = _USDC_ADDRESS;

        // Deploy a fresh ChainlinkAdaptor that we can manage
        chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        // Add asset to adaptor
        mockAggregator = new MockV3Aggregator(8, 1e8); // $1 price
        chainlinkAdaptor.addAsset(testAsset, true, address(mockAggregator), 0);
        oracleManager.addAssetPricingAdaptor(testAsset, address(chainlinkAdaptor), 100, 50, 100, 50);

        // Deploy ProtocolManager with manager and managed addresses
        // Both the adaptor AND the asset need authority
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(chainlinkAdaptor); // The adaptor being managed
        managedAddresses[1] = testAsset;                  // The asset being configured

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager, // The manager who can call setGuardedPriceConfig
            permsConfig,
            managedAddresses,
            limits
        );

        // Grant ProtocolManager market permissions so it can call setGuardedPriceConfig on adaptor
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful setGuardedPriceConfig with static price guard (ips = 0)
    /// @dev Price guards use e18 notation. Manager adjusts existing guard within period limits.
    function test_setGuardedPriceConfig_success_staticPriceGuard() public {
        // Set up existing price guard (simulating admin/DAO setup before ProtocolManager takes control)
        uint256 existingBasePrice = 1.02e18;  // $1.02 max for stablecoin
        uint256 existingMinPrice = 0.98e18;   // $0.98 min (below oracle's $1)

        chainlinkAdaptor.setGuardedPriceConfig(
            testAsset,
            true,
            0,
            0,
            existingBasePrice,
            existingMinPrice
        );

        // Manager adjusts within period limits (1e17 = $0.10)
        uint256 newBasePrice = existingBasePrice + 0.05e18;  // +$0.05
        uint256 newMinPrice = existingMinPrice - 0.02e18;    // -$0.02

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,           // inUSD
            0,              // timestampStart (must be 0 when ips = 0)
            0,              // ips (static mode)
            newBasePrice,
            newMinPrice
        );

        // Verify the price guard was set by checking the adaptor state
        (uint40 timestampStart, uint40 ips, uint88 storedBasePrice, uint88 storedMinPrice) =
            chainlinkAdaptor.priceGuards(testAsset, true);

        assertEq(timestampStart, 0, "timestampStart should be 0");
        assertEq(ips, 0, "ips should be 0");
        assertEq(storedBasePrice, newBasePrice, "basePrice mismatch");
        assertEq(storedMinPrice, newMinPrice, "minPrice mismatch");
    }

    /// @notice Test successful setGuardedPriceConfig with dynamic price guard (ips > 0)
    /// @dev Price guards use e18 notation. Manager adjusts existing guard within period limits.
    function test_setGuardedPriceConfig_success_dynamicPriceGuard() public {
        // Set up existing dynamic price guard (simulating admin/DAO setup)
        uint256 existingTimestampStart = block.timestamp - MINIMUM_TIMESTAMP_BUFFER - 1;
        uint256 existingIps = 1e10;
        uint256 existingBasePrice = 1.0e18;
        uint256 existingMinPrice = 0.95e18;

        chainlinkAdaptor.setGuardedPriceConfig(
            testAsset,
            true,
            existingTimestampStart,
            existingIps,
            existingBasePrice,
            existingMinPrice
        );

        // Manager adjusts within period limits
        uint256 newTimestampStart = block.timestamp - MINIMUM_TIMESTAMP_BUFFER - 1;
        uint256 newIps = 1e10;
        uint256 newBasePrice = existingBasePrice + 0.05e18;  // +$0.05
        uint256 newMinPrice = existingMinPrice + 0.01e18;    // +$0.01

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,           // inUSD
            newTimestampStart,
            newIps,
            newBasePrice,
            newMinPrice
        );

        // Verify the price guard was set
        (uint40 storedTimestampStart, uint40 storedIps, uint88 storedBasePrice, uint88 storedMinPrice) =
            chainlinkAdaptor.priceGuards(testAsset, true);

        assertEq(storedTimestampStart, newTimestampStart, "timestampStart mismatch");
        assertEq(storedIps, newIps, "ips mismatch");
        assertEq(storedBasePrice, newBasePrice, "basePrice mismatch");
        assertEq(storedMinPrice, newMinPrice, "minPrice mismatch");
    }

    /// @notice Test setGuardedPriceConfig for native token pricing (inUSD = false)
    /// @dev Price guards use e18 notation. Manager adjusts existing guard within period limits.
    function test_setGuardedPriceConfig_success_nativeTokenPricing() public {
        // First need to add native token pricing to the adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        // Set up existing native price guard (simulating admin/DAO setup)
        uint256 existingBasePrice = 1.0e18;
        uint256 existingMinPrice = 0.95e18;

        chainlinkAdaptor.setGuardedPriceConfig(
            testAsset,
            false,
            0,
            0,
            existingBasePrice,
            existingMinPrice
        );

        // Manager adjusts within period limits
        uint256 newBasePrice = existingBasePrice + 0.05e18;  // +0.05
        uint256 newMinPrice = existingMinPrice + 0.01e18;    // +0.01

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            false,          // inUSD = false (native token)
            0,
            0,
            newBasePrice,
            newMinPrice
        );

        // Verify the price guard was set for native token pricing
        (uint40 timestampStart, uint40 ips, uint88 storedBasePrice, uint88 storedMinPrice) =
            chainlinkAdaptor.priceGuards(testAsset, false);

        assertEq(storedBasePrice, newBasePrice, "basePrice mismatch");
        assertEq(storedMinPrice, newMinPrice, "minPrice mismatch");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setGuardedPriceConfig
    function test_setGuardedPriceConfig_fail_notCurator() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            1.05e18,
            0.96e18
        );
    }

    /// @notice Test that manager cannot manage adaptor without authority
    function test_setGuardedPriceConfig_fail_adaptorNoAuthority() public {
        // Deploy a new adaptor that doesn't have authority
        ChainlinkAdaptor unauthorizedAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(unauthorizedAdaptor));
        unauthorizedAdaptor.addAsset(testAsset, true, address(mockAggregator), 0);

        // Set up existing price guard on unauthorized adaptor
        unauthorizedAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setGuardedPriceConfig(
            address(unauthorizedAdaptor), // No authority for this adaptor
            testAsset,
            true,
            0,
            0,
            1.05e18,
            0.96e18
        );
    }

    /// @notice Test that manager cannot configure asset without authority
    function test_setGuardedPriceConfig_fail_assetNoAuthority() public {
        // Use an asset that doesn't have authority in the ProtocolManager
        address unauthorizedAsset = makeAddr("unauthorizedAsset");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            unauthorizedAsset, // No authority for this asset
            true,
            0,
            0,
            1.05e18,
            0.96e18
        );
    }

    /// @notice Test that setGuardedPriceConfig fails if canModifyPriceGuards is false
    function test_setGuardedPriceConfig_fail_noPermission() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        // Deploy a new ProtocolManager without canModifyPriceGuards permission
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(chainlinkAdaptor);
        managedAddresses[1] = testAsset;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = ProtocolManager.PermsConfig({
            canModifyPriceGuards: false, // Disabled
            canModifyTokenConfig: true,
            canModifyIRM: true,
            canUnpause: true,
            canModifyMintStatus: true,
            canModifyCollateralizationStatus: true,
            canModifyBorrowStatus: true,
            canModifyLiquidationStatus: true,
            canModifyRedeemStatus: true,
            canModifyTransferStatus: true,
            canModifyPositionManagers: true
        });

        ProtocolManager restrictedPM = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            permsConfig,
            managedAddresses,
            limits
        );

        centralRegistry.addMarketPermissions(address(restrictedPM));

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            1.05e18,
            0.96e18
        );
    }

    /// @notice Test that invalid timestamp (non-zero when ips = 0) reverts
    function test_setGuardedPriceConfig_fail_invalidTimestampStaticMode() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidTimestamp.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            block.timestamp - 10 days, // Should be 0 when ips = 0
            0,                          // ips = 0 (static mode)
            1.05e18,
            0.96e18
        );
    }

    /// @notice Test that timestamp in the future reverts
    function test_setGuardedPriceConfig_fail_timestampInFuture() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidTimestamp.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            block.timestamp + 1,  // Future timestamp
            1e10,                 // ips > 0 (dynamic mode)
            1.05e18,
            0.96e18
        );
    }

    /// @notice Test that timestamp too recent (< 7 days buffer) reverts
    function test_setGuardedPriceConfig_fail_timestampTooRecent() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidTimestamp.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            block.timestamp - 1 days, // Less than 7 days buffer
            1e10,
            1.05e18,
            0.96e18
        );
    }

    /// @notice Test that basePrice = 0 reverts
    function test_setGuardedPriceConfig_fail_basePriceZero() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            0,      // basePrice = 0 is invalid
            0
        );
    }

    /// @notice Test that minPrice > basePrice reverts
    function test_setGuardedPriceConfig_fail_minPriceAboveBasePrice() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            1e18,    // basePrice = $1
            2e18     // minPrice = $2 (greater than basePrice)
        );
    }

    /// @notice Test that ips exceeding uint40 max reverts
    function test_setGuardedPriceConfig_fail_ipsExceedsMax() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            block.timestamp - MINIMUM_TIMESTAMP_BUFFER - 1,
            uint256(type(uint40).max) + 1, // Exceeds uint40 max
            1.05e18,
            0.96e18
        );
    }

    /// @notice Test that basePrice exceeding uint88 max reverts
    function test_setGuardedPriceConfig_fail_basePriceExceedsMax() public {
        // Set up existing price guard
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, 1.02e18, 0.98e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            uint256(type(uint88).max) + 1, // Exceeds uint88 max
            0.96e18
        );
    }

    /// PERIOD ADJUSTMENT TESTS ///

    /// @notice Test that basePriceUSD adjustment is tracked correctly
    /// @dev Period adjustment tracks total change from period start.
    ///      With existing guard, adjustment = delta from existing value.
    ///      Limits: basePriceUSDLimit = 1e17, minPriceUSDLimit = 1e17
    function test_setGuardedPriceConfig_success_trackBasePriceUSDAdjustment() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // Manager adjusts within limit (1e17 = $0.10)
        uint256 newBasePrice = existingBasePrice + 0.05e18;  // +$0.05

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            existingMinPrice
        );

        // Verify adjustment tracked as delta (query by asset, not adaptor)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int88 basePriceUSDAdj,,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedAdj = int256(newBasePrice) - int256(existingBasePrice);
        assertEq(basePriceUSDAdj, int88(expectedAdj), "basePriceUSD adjustment mismatch");
    }

    /// @notice Test that minPriceUSD adjustment is tracked correctly
    function test_setGuardedPriceConfig_success_trackMinPriceUSDAdjustment() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // Manager adjusts within limit
        uint256 newMinPrice = existingMinPrice - 0.02e18;  // -$0.02

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            existingBasePrice,
            newMinPrice
        );

        // Verify adjustment tracked as delta (query by asset, not adaptor)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (, int88 minPriceUSDAdj,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedAdj = int256(newMinPrice) - int256(existingMinPrice);
        assertEq(minPriceUSDAdj, int88(expectedAdj), "minPriceUSD adjustment mismatch");
    }

    /// @notice Test that basePriceNative adjustment is tracked correctly
    function test_setGuardedPriceConfig_success_trackBasePriceNativeAdjustment() public {
        // First add native token pricing to the adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        // Set up existing native price guard
        uint256 existingBasePrice = 1.0e18;
        uint256 existingMinPrice = 0.95e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, false, 0, 0, existingBasePrice, existingMinPrice);

        // Manager adjusts
        uint256 newBasePrice = existingBasePrice + 0.05e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            false, // inUSD = false (native)
            0,
            0,
            newBasePrice,
            existingMinPrice
        );

        // Verify adjustment tracked as delta (query by asset, not adaptor)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,, int88 basePriceNativeAdj,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedAdj = int256(newBasePrice) - int256(existingBasePrice);
        assertEq(basePriceNativeAdj, int88(expectedAdj), "basePriceNative adjustment mismatch");
    }

    /// @notice Test that minPriceNative adjustment is tracked correctly
    function test_setGuardedPriceConfig_success_trackMinPriceNativeAdjustment() public {
        // First add native token pricing to the adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        // Set up existing native price guard
        uint256 existingBasePrice = 1.0e18;
        uint256 existingMinPrice = 0.95e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, false, 0, 0, existingBasePrice, existingMinPrice);

        // Manager adjusts
        uint256 newMinPrice = existingMinPrice + 0.02e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            false, // inUSD = false (native)
            0,
            0,
            existingBasePrice,
            newMinPrice
        );

        // Verify adjustment tracked as delta (query by asset, not adaptor)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,,, int88 minPriceNativeAdj) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedAdj = int256(newMinPrice) - int256(existingMinPrice);
        assertEq(minPriceNativeAdj, int88(expectedAdj), "minPriceNative adjustment mismatch");
    }

    /// @notice Test multiple updates within the same period - adjustment tracks total change from period start
    /// @dev adj = newValue - currentValue + existingAdj
    function test_setGuardedPriceConfig_success_cumulativeAdjustmentsInPeriod() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // First update: increase basePrice by 0.02e18
        uint256 basePrice1 = existingBasePrice + 0.02e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice1,
            existingMinPrice
        );

        // Second update: increase basePrice by another 0.02e18
        uint256 basePrice2 = basePrice1 + 0.02e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice2,
            existingMinPrice
        );

        // Third update: increase basePrice by another 0.02e18
        uint256 basePrice3 = basePrice2 + 0.02e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice3,
            existingMinPrice
        );

        // The cumulative adjustment = final - original = 0.06e18 (query by asset)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int88 basePriceUSDAdj,,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedAdj = int256(basePrice3) - int256(existingBasePrice);
        assertEq(basePriceUSDAdj, int88(expectedAdj), "cumulative adjustment should equal total delta");
    }

    /// @notice Test that decreasing price results in negative adjustment
    function test_setGuardedPriceConfig_success_decreasingPriceAdjustment() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.05e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // Manager decreases basePrice
        uint256 newBasePrice = existingBasePrice - 0.05e18;  // -$0.05

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            existingMinPrice
        );

        // Adjustment should be negative (query by asset)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int88 basePriceUSDAdj,,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedAdj = int256(newBasePrice) - int256(existingBasePrice);
        assertEq(basePriceUSDAdj, int88(expectedAdj), "adjustment should be negative delta");
        assertTrue(basePriceUSDAdj < 0, "adjustment should be negative");
    }

    /// @notice Test that basePriceUSD adjustment exceeding limit reverts
    /// @dev With existing guard, adjustment = delta. Limit is 1e17.
    function test_setGuardedPriceConfig_fail_basePriceUSDLimitExceeded() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // Try to adjust beyond the limit (1e17)
        uint256 newBasePrice = existingBasePrice + 1e17 + 1;  // Exceeds limit

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            existingMinPrice
        );
    }

    /// @notice Test that minPriceUSD adjustment exceeding limit reverts
    function test_setGuardedPriceConfig_fail_minPriceUSDLimitExceeded() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // Try to adjust beyond the limit (1e17)
        uint256 newMinPrice = existingMinPrice + 1e17 + 1;  // Exceeds limit

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            existingBasePrice,
            newMinPrice
        );
    }

    /// @notice Test that basePriceNative adjustment exceeding limit reverts
    function test_setGuardedPriceConfig_fail_basePriceNativeLimitExceeded() public {
        // First add native token pricing to the adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        // Set up existing native price guard
        uint256 existingBasePrice = 1.0e18;
        uint256 existingMinPrice = 0.95e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, false, 0, 0, existingBasePrice, existingMinPrice);

        // Try to adjust beyond the limit (1e17)
        uint256 newBasePrice = existingBasePrice + 1e17 + 1;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            false,
            0,
            0,
            newBasePrice,
            existingMinPrice
        );
    }

    /// @notice Test that minPriceNative adjustment exceeding limit reverts
    function test_setGuardedPriceConfig_fail_minPriceNativeLimitExceeded() public {
        // First add native token pricing to the adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        // Set up existing native price guard
        uint256 existingBasePrice = 1.0e18;
        uint256 existingMinPrice = 0.95e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, false, 0, 0, existingBasePrice, existingMinPrice);

        // Try to adjust beyond the limit (1e17)
        uint256 newMinPrice = existingMinPrice + 1e17 + 1;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            false,
            0,
            0,
            existingBasePrice,
            newMinPrice
        );
    }

    /// @notice Test that cumulative adjustments exceeding limit reverts
    /// @dev Multiple updates within period accumulate towards the limit
    function test_setGuardedPriceConfig_fail_cumulativeUpdateExceedsLimit() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // First update: increase by 0.05e18 (within limit)
        uint256 basePrice1 = existingBasePrice + 0.05e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice1,
            existingMinPrice
        );

        // Second update: try to increase by another 0.06e18 (cumulative 0.11e18 > 0.1e18 limit)
        uint256 basePrice2 = basePrice1 + 0.06e18;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice2,
            existingMinPrice
        );
    }

    /// @notice Test that adjustments reset after period ends
    function test_setGuardedPriceConfig_success_adjustmentsResetAfterPeriod() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // First update in current period
        uint256 basePrice1 = existingBasePrice + 0.05e18;
        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice1,
            existingMinPrice
        );

        // Verify adjustment tracked (query by asset)
        uint256 periodTimestamp1 = protocolManager.getPeriodTimestamp();
        (int88 adj1,,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp1
        );
        int256 expectedAdj1 = int256(basePrice1) - int256(existingBasePrice);
        assertEq(adj1, int88(expectedAdj1), "First period adjustment");

        // Warp forward past the period duration (1 week)
        vm.warp(block.timestamp + 604800 + 1);

        // Update mock oracle to avoid stale data error
        mockAggregator.updateAnswer(1e8);

        // In new period, adjustment resets - can adjust again from new baseline
        uint256 basePrice2 = basePrice1 + 0.05e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice2,
            existingMinPrice
        );

        // Verify new period has fresh adjustment (delta from period start value, query by asset)
        uint256 periodTimestamp2 = protocolManager.getPeriodTimestamp();
        (int88 adj2,,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp2
        );

        // New period adjustment = basePrice2 - basePrice1 = 0.05e18
        int256 expectedAdj2 = int256(basePrice2) - int256(basePrice1);
        assertEq(adj2, int88(expectedAdj2), "New period should track delta from period start value");
    }

    /// @notice Test that both USD price adjustments are tracked together
    function test_setGuardedPriceConfig_success_trackBothUSDAdjustments() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // Manager adjusts both
        uint256 newBasePrice = existingBasePrice + 0.05e18;
        uint256 newMinPrice = existingMinPrice - 0.02e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            newMinPrice
        );

        // Verify both adjustments tracked as deltas (query by asset)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int88 basePriceUSDAdj, int88 minPriceUSDAdj,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedBaseAdj = int256(newBasePrice) - int256(existingBasePrice);
        int256 expectedMinAdj = int256(newMinPrice) - int256(existingMinPrice);
        assertEq(basePriceUSDAdj, int88(expectedBaseAdj), "basePriceUSD adjustment mismatch");
        assertEq(minPriceUSDAdj, int88(expectedMinAdj), "minPriceUSD adjustment mismatch");
    }

    /// @notice Test period adjustment when price guard already exists (real-world scenario)
    /// @dev When managing an adaptor with existing price guard, adjustment is delta from current value.
    ///      Price guards are typically used for stablecoins (~$1) or yield-bearing ratios (~1.0).
    ///      The mock oracle returns $1, so minPrice must be < $1.
    function test_setGuardedPriceConfig_success_existingPriceGuard() public {
        // Simulate existing price guard for a stablecoin (USDC at ~$1)
        // basePrice = max allowed price, minPrice = min allowed price (must be < oracle price)
        uint256 existingBasePrice = 1.02e18;  // $1.02 max
        uint256 existingMinPrice = 0.98e18;   // $0.98 min (below oracle's $1)

        // Set price guard directly on adaptor (simulating pre-existing state)
        chainlinkAdaptor.setGuardedPriceConfig(
            testAsset,
            true,
            0,
            0,
            existingBasePrice,
            existingMinPrice
        );

        // Now manager updates the price guard
        // Limits are: basePriceUSDLimit = 1e17, minPriceUSDLimit = 1e17
        uint256 newBasePrice = existingBasePrice + 0.01e18;  // +$0.01 (within limit)
        uint256 newMinPrice = existingMinPrice + 0.005e18;   // +$0.005 (within limit)

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            newMinPrice
        );

        // Verify adjustment is the DELTA from existing value, not absolute (query by asset)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (int88 basePriceUSDAdj, int88 minPriceUSDAdj,,) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedBaseAdj = int256(newBasePrice) - int256(existingBasePrice);
        int256 expectedMinAdj = int256(newMinPrice) - int256(existingMinPrice);

        assertEq(basePriceUSDAdj, int88(expectedBaseAdj), "adjustment should be delta from existing value");
        assertEq(minPriceUSDAdj, int88(expectedMinAdj), "minPrice adjustment should be delta");
    }

    /// @notice Test that limit applies to delta when price guard exists
    /// @dev For stablecoins/ratios, this allows adjusting guards even when values are near limits
    function test_setGuardedPriceConfig_success_limitAppliesToDeltaWithExistingGuard() public {
        // Set existing price guard for stablecoin - already near the edge of typical range
        uint256 existingBasePrice = 1.05e18;  // $1.05 max
        uint256 existingMinPrice = 0.95e18;   // $0.95 min

        chainlinkAdaptor.setGuardedPriceConfig(
            testAsset,
            true,
            0,
            0,
            existingBasePrice,
            existingMinPrice
        );

        // Manager can adjust within period limit (1e17) from existing value
        uint256 newBasePrice = existingBasePrice + 0.02e18;  // +$0.02 (within 1e17 limit)

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            existingMinPrice
        );

        // Verify the change was allowed
        (,, uint88 storedBasePrice,) = chainlinkAdaptor.priceGuards(testAsset, true);
        assertEq(storedBasePrice, newBasePrice, "price should be updated");
    }

    /// @notice Test that manager CANNOT set price guard on asset with no existing guard if value exceeds limit
    /// @dev This is by design - initial price guards should be set by DAO/admin, not ProtocolManager.
    ///      ProtocolManager is for adjustments, not initial setup. With basePriceUSDLimit = 1e17,
    ///      manager can only set initial basePrice up to $0.10.
    function test_setGuardedPriceConfig_fail_noExistingGuardLimitedByAbsoluteValue() public {
        // No existing price guard, so pg.basePrice = 0
        // Trying to set any realistic stablecoin price (~$1) exceeds the 1e17 ($0.10) limit
        uint256 basePrice = 1e18; // $1.00 - WAY over the 1e17 limit
        uint256 minPrice = 0.5e18;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice,
            minPrice
        );
    }

    /// @notice Test the maximum price a manager can set when no price guard exists
    /// @dev With basePriceUSDLimit = 1e17, max initial basePrice is $0.10
    ///      This demonstrates why initial guards should be set by admin, not ProtocolManager.
    function test_setGuardedPriceConfig_success_maxInitialPriceWithNoExistingGuard() public {
        // No existing price guard - manager can only set up to the limit
        uint256 basePrice = 1e17;   // Exactly at limit ($0.10)
        uint256 minPrice = 0.5e17;  // Half the limit ($0.05)

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            basePrice,
            minPrice
        );

        (,, uint88 storedBasePrice, uint88 storedMinPrice) = chainlinkAdaptor.priceGuards(testAsset, true);
        assertEq(storedBasePrice, basePrice, "basePrice should be set to limit");
        assertEq(storedMinPrice, minPrice, "minPrice should be set to value");
    }

    /// @notice Test that USD and native adjustments are tracked independently
    function test_setGuardedPriceConfig_success_independentUSDAndNativeAdjustments() public {
        // Add native token pricing
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        // Set up existing USD price guard
        uint256 existingUSDBasePrice = 1.02e18;
        uint256 existingUSDMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingUSDBasePrice, existingUSDMinPrice);

        // Set up existing native price guard
        uint256 existingNativeBasePrice = 1.0e18;
        uint256 existingNativeMinPrice = 0.95e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, false, 0, 0, existingNativeBasePrice, existingNativeMinPrice);

        // Manager adjusts USD price guard
        uint256 newUSDBasePrice = existingUSDBasePrice + 0.03e18;
        uint256 newUSDMinPrice = existingUSDMinPrice - 0.01e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true, // USD
            0,
            0,
            newUSDBasePrice,
            newUSDMinPrice
        );

        // Manager adjusts native price guard
        uint256 newNativeBasePrice = existingNativeBasePrice + 0.05e18;
        uint256 newNativeMinPrice = existingNativeMinPrice + 0.02e18;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            false, // Native
            0,
            0,
            newNativeBasePrice,
            newNativeMinPrice
        );

        // Verify all adjustments tracked independently as deltas (query by asset)
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (
            int88 basePriceUSDAdj,
            int88 minPriceUSDAdj,
            int88 basePriceNativeAdj,
            int88 minPriceNativeAdj
        ) = protocolManager.getPriceGuardPeriodAdjustments(
            testAsset,  // Query by asset, not adaptor
            periodTimestamp
        );

        int256 expectedUSDBaseAdj = int256(newUSDBasePrice) - int256(existingUSDBasePrice);
        int256 expectedUSDMinAdj = int256(newUSDMinPrice) - int256(existingUSDMinPrice);
        int256 expectedNativeBaseAdj = int256(newNativeBasePrice) - int256(existingNativeBasePrice);
        int256 expectedNativeMinAdj = int256(newNativeMinPrice) - int256(existingNativeMinPrice);

        assertEq(basePriceUSDAdj, int88(expectedUSDBaseAdj), "basePriceUSD mismatch");
        assertEq(minPriceUSDAdj, int88(expectedUSDMinAdj), "minPriceUSD mismatch");
        assertEq(basePriceNativeAdj, int88(expectedNativeBaseAdj), "basePriceNative mismatch");
        assertEq(minPriceNativeAdj, int88(expectedNativeMinAdj), "minPriceNative mismatch");
    }
}

