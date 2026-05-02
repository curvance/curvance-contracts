// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.disableGuardedPriceConfigCombined
contract TestProtocolManagerDisableGuardedPriceConfigCombined is TestProtocolManagerBase {

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
        primaryAggregator = new MockV3Aggregator(8, 2000e8);
        secondaryAggregator = new MockV3Aggregator(18, 1.05e18);

        // Deploy CombinedAggregator
        combinedAggregator = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAggregator),
            address(secondaryAggregator),
            0,
            "stETH/USD"
        );

        // Deploy a fresh ChainlinkAdaptor that uses the CombinedAggregator.
        chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(testAsset, true, address(combinedAggregator), 0);

        address[] memory oldAdaptors = oracleManager.getPricingAdaptors(testAsset);
        oracleManager.replaceAssetPricingAdaptor(
            testAsset,
            oldAdaptors[0],
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );

        // Deploy ProtocolManager with manager and managed addresses
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

        // Grant ProtocolManager market permissions
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful disable of static price guard on combined aggregator
    function test_disableGuardedPriceConfigCombined_success() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.10e18;
        uint256 existingMinPrice = 1.0e18;
        combinedAggregator.setGuardedPriceConfig(0, 0, existingBasePrice, existingMinPrice);

        // Verify price guard is set
        (,, uint88 basePrice, uint88 minPrice) = combinedAggregator.pg();
        assertEq(basePrice, existingBasePrice, "basePrice should be set");
        assertEq(minPrice, existingMinPrice, "minPrice should be set");

        // Manager disables price guard
        vm.prank(manager);
        protocolManager.disableGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true
        );

        // Verify price guard is disabled (all values should be 0)
        (uint40 pgTimestampStart, uint40 pgIps, uint88 pgBasePrice, uint88 pgMinPrice) =
            combinedAggregator.pg();

        assertEq(pgTimestampStart, 0, "timestampStart should be 0");
        assertEq(pgIps, 0, "ips should be 0");
        assertEq(pgBasePrice, 0, "basePrice should be 0");
        assertEq(pgMinPrice, 0, "minPrice should be 0");
    }

    /// @notice Test that dynamic price guard can be disabled
    function test_disableGuardedPriceConfigCombined_success_dynamicPriceGuard() public {
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

        // Verify price guard is set
        (uint40 ts, uint40 ips,,) = combinedAggregator.pg();
        assertEq(ts, existingTimestampStart, "timestampStart should be set");
        assertEq(ips, existingIps, "ips should be set");

        // Manager disables price guard
        vm.prank(manager);
        protocolManager.disableGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true
        );

        // Verify price guard is disabled
        (uint40 pgTimestampStart, uint40 pgIps, uint88 pgBasePrice, uint88 pgMinPrice) =
            combinedAggregator.pg();

        assertEq(pgTimestampStart, 0, "timestampStart should be 0");
        assertEq(pgIps, 0, "ips should be 0");
        assertEq(pgBasePrice, 0, "basePrice should be 0");
        assertEq(pgMinPrice, 0, "minPrice should be 0");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot disable price guard
    function test_disableGuardedPriceConfigCombined_fail_notManager() public {
        // Set up existing price guard
        combinedAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.disableGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true
        );
    }

    /// @notice Test that manager cannot disable aggregator without authority
    function test_disableGuardedPriceConfigCombined_fail_noAuthority() public {
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
        protocolManager.disableGuardedPriceConfigCombined(
            address(unauthorizedAgg),
            testAsset,
            true
        );
    }

    /// @notice Test that manager cannot disable through an unauthorized asset.
    function test_disableGuardedPriceConfigCombined_fail_assetNoAuthority() public {
        address unauthorizedAsset = makeAddr("unauthorizedAsset");

        combinedAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.disableGuardedPriceConfigCombined(
            address(combinedAggregator),
            unauthorizedAsset,
            true
        );
    }

    /// @notice Test that manager cannot disable through the wrong oracle mapping.
    function test_disableGuardedPriceConfigCombined_fail_wrongAggregatorMapping() public {
        CombinedAggregator otherAggregator = new CombinedAggregator(
            ICentralRegistry(address(centralRegistry)),
            address(primaryAggregator),
            address(secondaryAggregator),
            0,
            "other"
        );

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

        otherAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        pm.disableGuardedPriceConfigCombined(
            address(otherAggregator),
            testAsset,
            true
        );
    }

    /// @notice Test that canDisablePriceGuards permission is required
    function test_disableGuardedPriceConfigCombined_fail_noDisablePermission() public {
        // Set up existing price guard
        combinedAggregator.setGuardedPriceConfig(0, 0, 1.10e18, 1.0e18);

        // Create ProtocolManager without canDisablePriceGuards permission
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(combinedAggregator);
        managedAddresses[1] = testAsset;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: false,  // Disabled
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

        ProtocolManager pmNoDisable = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            permsConfig,
            managedAddresses,
            limits
        );
        centralRegistry.addMarketPermissions(address(pmNoDisable));

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        pmNoDisable.disableGuardedPriceConfigCombined(
            address(combinedAggregator),
            testAsset,
            true
        );
    }
}
