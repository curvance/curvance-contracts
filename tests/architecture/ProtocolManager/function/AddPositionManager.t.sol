// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

/// @notice Tests for ProtocolManager.addPositionManager
/// @dev The manager (protocolManager address) calls addPositionManager to add
///      a position manager to a MarketManagerIsolated contract.
///      Note: Only the marketManager needs authority (uses _checkAuthority).
contract TestProtocolManagerAddPositionManager is TestProtocolManagerBase {

    address public manager;
    SimplePositionManager public positionManager;

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");

        // Deploy a SimplePositionManager to use in tests
        positionManager = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            WMON_ADDRESS
        );

        // Deploy ProtocolManager with the MarketManager as a managed address
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            permsConfig,
            managedAddresses,
            limits
        );

        // Grant ProtocolManager market permissions so it can call addPositionManager
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful adding of a position manager
    function test_addPositionManager_success() public {
        // Verify position manager is not added initially
        assertFalse(
            marketManagerIsolated.isPositionManager(address(positionManager)),
            "Position manager should not be added initially"
        );

        vm.prank(manager);
        protocolManager.addPositionManager(
            address(marketManagerIsolated),
            address(positionManager)
        );

        // Verify position manager is now added
        assertTrue(
            marketManagerIsolated.isPositionManager(address(positionManager)),
            "Position manager should be added"
        );
    }

    /// @notice Test adding multiple different position managers
    function test_addPositionManager_success_multipleManagers() public {
        // Deploy a second position manager
        SimplePositionManager positionManager2 = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            WMON_ADDRESS
        );

        // Add first position manager
        vm.prank(manager);
        protocolManager.addPositionManager(address(marketManagerIsolated), address(positionManager));
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager)));

        // Add second position manager
        vm.prank(manager);
        protocolManager.addPositionManager(address(marketManagerIsolated), address(positionManager2));
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager2)));

        // Both should still be position managers
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager)));
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager2)));
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call addPositionManager
    function test_addPositionManager_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.addPositionManager(
            address(marketManagerIsolated),
            address(positionManager)
        );
    }

    /// @notice Test that manager cannot add position manager without market authority
    function test_addPositionManager_fail_noMarketAuthority() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.addPositionManager(
            unauthorizedMarket,
            address(positionManager)
        );
    }

    /// @notice Test that addPositionManager fails when canModifyPositionManagers is false
    function test_addPositionManager_fail_canModifyPositionManagersDisabled() public {
        // Deploy ProtocolManager with canModifyPositionManagers = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canModifyTokenConfig: true,
            canModifyIRM: true,
            canUnpause: true,
            canModifyMintStatus: true,
            canModifyCollateralizationStatus: true,
            canModifyBorrowStatus: true,
            canModifyLiquidationStatus: true,
            canModifyRedeemStatus: true,
            canModifyTransferStatus: true,
            canModifyPositionManagers: false // Disabled
        });

        ProtocolManager restrictedPM = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            restrictedPerms,
            managedAddresses,
            limits
        );

        // Grant market permissions
        centralRegistry.addMarketPermissions(address(restrictedPM));

        // Verify canModifyPositionManagers is false
        assertFalse(restrictedPM.canModifyPositionManagers(), "canModifyPositionManagers should be false");

        // Try to add position manager - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.addPositionManager(
            address(marketManagerIsolated),
            address(positionManager)
        );
    }

    /// @notice Test that adding same position manager twice fails (at MarketManager level)
    function test_addPositionManager_fail_alreadyAdded() public {
        // Add position manager first time
        vm.prank(manager);
        protocolManager.addPositionManager(address(marketManagerIsolated), address(positionManager));
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager)));

        // Try to add same position manager again - should revert at MarketManager level
        vm.prank(manager);
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        protocolManager.addPositionManager(address(marketManagerIsolated), address(positionManager));
    }

    /// @notice Test that adding an address that doesn't implement IPositionManager fails
    function test_addPositionManager_fail_notPositionManager() public {
        address notPM = makeAddr("notPositionManager");

        // Try to add an address that doesn't implement IPositionManager
        vm.prank(manager);
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        protocolManager.addPositionManager(address(marketManagerIsolated), notPM);
    }

    /// @notice Verify permission flags are correctly set
    function test_addPositionManager_verifyPermissions() public view {
        assertTrue(protocolManager.canModifyPositionManagers(), "canModifyPositionManagers should be true");
    }
}

