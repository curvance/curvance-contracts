// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.disableGuardedPriceConfig
/// @dev The manager (protocolManager address) calls disableGuardedPriceConfig to remove price guards
///      from oracle adaptors. Both the adaptor and asset must have authority in the config.
contract TestProtocolManagerDisableGuardedPriceConfig is TestProtocolManagerBase {

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
            manager, // The manager who can call disableGuardedPriceConfig
            permsConfig,
            managedAddresses,
            limits
        );

        // Grant ProtocolManager market permissions so it can call functions on adaptor
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// @notice Helper to set up a price guard that we can then disable
    function _setupPriceGuard(bool inUSD) internal {
        uint256 basePrice = 2e8;
        uint256 minPrice = 0.5e8;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            inUSD,
            0,      // static mode
            0,
            basePrice,
            minPrice
        );

        // Verify price guard was set
        (,, uint88 storedBasePrice,) = chainlinkAdaptor.priceGuards(testAsset, inUSD);
        assertEq(storedBasePrice, basePrice, "price guard should be set");
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful disableGuardedPriceConfig for USD pricing
    function test_disableGuardedPriceConfig_success_usdPricing() public {
        // First set up a price guard
        _setupPriceGuard(true);

        // Disable it
        vm.prank(manager);
        protocolManager.disableGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true    // inUSD
        );

        // Verify the price guard was disabled (all values should be 0)
        (uint40 timestampStart, uint40 ips, uint88 storedBasePrice, uint88 storedMinPrice) = 
            chainlinkAdaptor.priceGuards(testAsset, true);
        
        assertEq(timestampStart, 0, "timestampStart should be 0");
        assertEq(ips, 0, "ips should be 0");
        assertEq(storedBasePrice, 0, "basePrice should be 0");
        assertEq(storedMinPrice, 0, "minPrice should be 0");
    }

    /// @notice Test successful disableGuardedPriceConfig for native token pricing
    function test_disableGuardedPriceConfig_success_nativeTokenPricing() public {
        // First add native token pricing to the adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        // Set up a price guard for native token pricing
        _setupPriceGuard(false);

        // Disable it
        vm.prank(manager);
        protocolManager.disableGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            false   // inUSD = false (native token)
        );

        // Verify the price guard was disabled
        (uint40 timestampStart, uint40 ips, uint88 storedBasePrice, uint88 storedMinPrice) = 
            chainlinkAdaptor.priceGuards(testAsset, false);
        
        assertEq(timestampStart, 0, "timestampStart should be 0");
        assertEq(ips, 0, "ips should be 0");
        assertEq(storedBasePrice, 0, "basePrice should be 0");
        assertEq(storedMinPrice, 0, "minPrice should be 0");
    }

    /// @notice Test disabling a price guard that doesn't exist (should still succeed - idempotent)
    function test_disableGuardedPriceConfig_success_noExistingGuard() public {
        // Don't set up any price guard, just try to disable
        vm.prank(manager);
        protocolManager.disableGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true
        );

        // Verify all values are still 0
        (uint40 timestampStart, uint40 ips, uint88 storedBasePrice, uint88 storedMinPrice) = 
            chainlinkAdaptor.priceGuards(testAsset, true);
        
        assertEq(timestampStart, 0, "timestampStart should be 0");
        assertEq(ips, 0, "ips should be 0");
        assertEq(storedBasePrice, 0, "basePrice should be 0");
        assertEq(storedMinPrice, 0, "minPrice should be 0");
    }

    /// @notice Test that disabling USD guard doesn't affect native token guard
    function test_disableGuardedPriceConfig_success_independentGuards() public {
        // Add native token pricing to the adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        // Set up both price guards
        _setupPriceGuard(true);   // USD
        _setupPriceGuard(false);  // Native

        // Disable only the USD guard
        vm.prank(manager);
        protocolManager.disableGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true    // Only USD
        );

        // Verify USD guard is disabled
        (,, uint88 usdBasePrice,) = chainlinkAdaptor.priceGuards(testAsset, true);
        assertEq(usdBasePrice, 0, "USD basePrice should be 0");

        // Verify native guard is still active
        (,, uint88 nativeBasePrice,) = chainlinkAdaptor.priceGuards(testAsset, false);
        assertEq(nativeBasePrice, 2e8, "native basePrice should still be set");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call disableGuardedPriceConfig
    function test_disableGuardedPriceConfig_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.disableGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true
        );
    }

    /// @notice Test that manager cannot manage adaptor without authority
    function test_disableGuardedPriceConfig_fail_adaptorNoAuthority() public {
        // Deploy a new adaptor that doesn't have authority
        ChainlinkAdaptor unauthorizedAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(unauthorizedAdaptor));
        unauthorizedAdaptor.addAsset(testAsset, true, address(mockAggregator), 0);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.disableGuardedPriceConfig(
            address(unauthorizedAdaptor), // No authority for this adaptor
            testAsset,
            true
        );
    }

    /// @notice Test that manager cannot configure asset without authority
    function test_disableGuardedPriceConfig_fail_assetNoAuthority() public {
        // Use an asset that doesn't have authority in the ProtocolManager
        address unauthorizedAsset = makeAddr("unauthorizedAsset");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.disableGuardedPriceConfig(
            address(chainlinkAdaptor),
            unauthorizedAsset, // No authority for this asset
            true
        );
    }

    /// @notice Test that disableGuardedPriceConfig fails if canDisablePriceGuards is false
    /// @dev Tests the separate permission for disabling vs modifying price guards
    function test_disableGuardedPriceConfig_fail_noDisablePermission() public {
        // Deploy a new ProtocolManager with canModifyPriceGuards but without canDisablePriceGuards
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(chainlinkAdaptor);
        managedAddresses[1] = testAsset;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,   // Can modify
            canDisablePriceGuards: false, // But cannot disable
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

        // Should fail even though canModifyPriceGuards is true
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.disableGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true
        );
    }

    /// @notice Test that canModifyPriceGuards allows setGuardedPriceConfig even when canDisablePriceGuards is false
    /// @dev Confirms the two permissions are independent
    function test_separatePermissions_canModifyButNotDisable() public {
        // Set up existing price guard
        uint256 existingBasePrice = 1.02e18;
        uint256 existingMinPrice = 0.98e18;
        chainlinkAdaptor.setGuardedPriceConfig(testAsset, true, 0, 0, existingBasePrice, existingMinPrice);

        // Deploy a new ProtocolManager with canModifyPriceGuards but without canDisablePriceGuards
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(chainlinkAdaptor);
        managedAddresses[1] = testAsset;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,   // Can modify
            canDisablePriceGuards: false, // But cannot disable
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

        // Modifying should succeed
        uint256 newBasePrice = existingBasePrice + 0.01e18;
        vm.prank(manager);
        restrictedPM.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            newBasePrice,
            existingMinPrice
        );

        // Verify modification worked
        (,, uint88 storedBasePrice,) = chainlinkAdaptor.priceGuards(testAsset, true);
        assertEq(storedBasePrice, newBasePrice, "basePrice should be updated");

        // But disabling should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.disableGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true
        );
    }
}

