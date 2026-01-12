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
    function test_setGuardedPriceConfig_success_staticPriceGuard() public {
        uint256 basePrice = 2e8;  // $2 max price
        uint256 minPrice = 0.5e8; // $0.50 min price

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,           // inUSD
            0,              // timestampStart (must be 0 when ips = 0)
            0,              // ips (static mode)
            basePrice,
            minPrice
        );

        // Verify the price guard was set by checking the adaptor state
        (uint40 timestampStart, uint40 ips, uint88 storedBasePrice, uint88 storedMinPrice) = 
            chainlinkAdaptor.priceGuards(testAsset, true);
        
        assertEq(timestampStart, 0, "timestampStart should be 0");
        assertEq(ips, 0, "ips should be 0");
        assertEq(storedBasePrice, basePrice, "basePrice mismatch");
        assertEq(storedMinPrice, minPrice, "minPrice mismatch");
    }

    /// @notice Test successful setGuardedPriceConfig with dynamic price guard (ips > 0)
    function test_setGuardedPriceConfig_success_dynamicPriceGuard() public {
        // timestampStart must be at least 7 days in the past
        uint256 timestampStart = block.timestamp - MINIMUM_TIMESTAMP_BUFFER - 1;
        uint256 ips = 1e10;       // Growth rate per second
        uint256 basePrice = 2e8;  // $2 max price
        uint256 minPrice = 0.5e8; // $0.50 min price

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,           // inUSD
            timestampStart,
            ips,
            basePrice,
            minPrice
        );

        // Verify the price guard was set
        (uint40 storedTimestampStart, uint40 storedIps, uint88 storedBasePrice, uint88 storedMinPrice) = 
            chainlinkAdaptor.priceGuards(testAsset, true);
        
        assertEq(storedTimestampStart, timestampStart, "timestampStart mismatch");
        assertEq(storedIps, ips, "ips mismatch");
        assertEq(storedBasePrice, basePrice, "basePrice mismatch");
        assertEq(storedMinPrice, minPrice, "minPrice mismatch");
    }

    /// @notice Test setGuardedPriceConfig for native token pricing (inUSD = false)
    function test_setGuardedPriceConfig_success_nativeTokenPricing() public {
        // First need to add native token pricing to the adaptor
        chainlinkAdaptor.addAsset(testAsset, false, address(mockAggregator), 0);

        uint256 basePrice = 2e8;
        uint256 minPrice = 0.5e8;

        vm.prank(manager);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            false,          // inUSD = false (native token)
            0,
            0,
            basePrice,
            minPrice
        );

        // Verify the price guard was set for native token pricing
        (uint40 timestampStart, uint40 ips, uint88 storedBasePrice, uint88 storedMinPrice) = 
            chainlinkAdaptor.priceGuards(testAsset, false);
        
        assertEq(storedBasePrice, basePrice, "basePrice mismatch");
        assertEq(storedMinPrice, minPrice, "minPrice mismatch");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setGuardedPriceConfig
    function test_setGuardedPriceConfig_fail_notCurator() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            2e8,
            0.5e8
        );
    }

    /// @notice Test that manager cannot manage adaptor without authority
    function test_setGuardedPriceConfig_fail_adaptorNoAuthority() public {
        // Deploy a new adaptor that doesn't have authority
        ChainlinkAdaptor unauthorizedAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(unauthorizedAdaptor));
        unauthorizedAdaptor.addAsset(testAsset, true, address(mockAggregator), 0);

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setGuardedPriceConfig(
            address(unauthorizedAdaptor), // No authority for this adaptor
            testAsset,
            true,
            0,
            0,
            2e8,
            0.5e8
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
            2e8,
            0.5e8
        );
    }

    /// @notice Test that setGuardedPriceConfig fails if canModifyPriceGuards is false
    function test_setGuardedPriceConfig_fail_noPermission() public {
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
            2e8,
            0.5e8
        );
    }

    /// @notice Test that invalid timestamp (non-zero when ips = 0) reverts
    function test_setGuardedPriceConfig_fail_invalidTimestampStaticMode() public {
        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidTimestamp.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            block.timestamp - 10 days, // Should be 0 when ips = 0
            0,                          // ips = 0 (static mode)
            2e8,
            0.5e8
        );
    }

    /// @notice Test that timestamp in the future reverts
    function test_setGuardedPriceConfig_fail_timestampInFuture() public {
        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidTimestamp.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            block.timestamp + 1,  // Future timestamp
            1e10,                 // ips > 0 (dynamic mode)
            2e8,
            0.5e8
        );
    }

    /// @notice Test that timestamp too recent (< 7 days buffer) reverts
    function test_setGuardedPriceConfig_fail_timestampTooRecent() public {
        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidTimestamp.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            block.timestamp - 1 days, // Less than 7 days buffer
            1e10,
            2e8,
            0.5e8
        );
    }

    /// @notice Test that basePrice = 0 reverts
    function test_setGuardedPriceConfig_fail_basePriceZero() public {
        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
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
        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            1e8,    // basePrice = $1
            2e8     // minPrice = $2 (greater than basePrice)
        );
    }

    /// @notice Test that ips exceeding uint40 max reverts
    function test_setGuardedPriceConfig_fail_ipsExceedsMax() public {
        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            block.timestamp - MINIMUM_TIMESTAMP_BUFFER - 1,
            uint256(type(uint40).max) + 1, // Exceeds uint40 max
            2e8,
            0.5e8
        );
    }

    /// @notice Test that basePrice exceeding uint88 max reverts
    function test_setGuardedPriceConfig_fail_basePriceExceedsMax() public {
        vm.prank(manager);
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        protocolManager.setGuardedPriceConfig(
            address(chainlinkAdaptor),
            testAsset,
            true,
            0,
            0,
            uint256(type(uint88).max) + 1, // Exceeds uint88 max
            0.5e8
        );
    }
}

