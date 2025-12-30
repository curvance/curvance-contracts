// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

/// @notice Tests for ProtocolManager.removePositionManager
/// @dev The manager (protocolManager address) calls removePositionManager to remove
///      a position manager from a MarketManagerIsolated contract.
///      Note: Only the marketManager needs authority (uses _checkAuthority).
contract TestProtocolManagerRemovePositionManager is TestProtocolManagerBase {

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

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            permsConfig,
            managedAddresses,
            limits
        );

        // Grant ProtocolManager market permissions so it can call add/removePositionManager
        centralRegistry.addMarketPermissions(address(protocolManager));

        // Add the position manager first so we can test removing it
        vm.prank(manager);
        protocolManager.addPositionManager(address(marketManagerIsolated), address(positionManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful removal of a position manager
    function test_removePositionManager_success() public {
        // Verify position manager is added
        assertTrue(
            marketManagerIsolated.isPositionManager(address(positionManager)),
            "Position manager should be added initially"
        );

        vm.prank(manager);
        protocolManager.removePositionManager(
            address(marketManagerIsolated),
            address(positionManager)
        );

        // Verify position manager is now removed
        assertFalse(
            marketManagerIsolated.isPositionManager(address(positionManager)),
            "Position manager should be removed"
        );
    }

    /// @notice Test adding and removing multiple different position managers
    function test_removePositionManager_success_multipleManagers() public {
        // Deploy and add a second position manager
        SimplePositionManager positionManager2 = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            WMON_ADDRESS
        );
        vm.prank(manager);
        protocolManager.addPositionManager(address(marketManagerIsolated), address(positionManager2));

        // Verify both are added
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager)));
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager2)));

        // Remove first position manager
        vm.prank(manager);
        protocolManager.removePositionManager(address(marketManagerIsolated), address(positionManager));

        // Verify first is removed but second is still there
        assertFalse(marketManagerIsolated.isPositionManager(address(positionManager)));
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager2)));

        // Remove second position manager
        vm.prank(manager);
        protocolManager.removePositionManager(address(marketManagerIsolated), address(positionManager2));

        // Verify both are now removed
        assertFalse(marketManagerIsolated.isPositionManager(address(positionManager)));
        assertFalse(marketManagerIsolated.isPositionManager(address(positionManager2)));
    }

    /// @notice Test that a position manager can be re-added after removal
    function test_removePositionManager_success_readdAfterRemoval() public {
        // Remove position manager
        vm.prank(manager);
        protocolManager.removePositionManager(address(marketManagerIsolated), address(positionManager));
        assertFalse(marketManagerIsolated.isPositionManager(address(positionManager)));

        // Re-add position manager
        vm.prank(manager);
        protocolManager.addPositionManager(address(marketManagerIsolated), address(positionManager));
        assertTrue(marketManagerIsolated.isPositionManager(address(positionManager)));
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call removePositionManager
    function test_removePositionManager_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.removePositionManager(
            address(marketManagerIsolated),
            address(positionManager)
        );
    }

    /// @notice Test that manager cannot remove position manager without market authority
    function test_removePositionManager_fail_noMarketAuthority() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.removePositionManager(
            unauthorizedMarket,
            address(positionManager)
        );
    }

    /// @notice Test that removePositionManager fails when canModifyPositionManagers is false
    function test_removePositionManager_fail_canModifyPositionManagersDisabled() public {
        // Deploy ProtocolManager with canModifyPositionManagers = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
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

        // Try to remove position manager - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.removePositionManager(
            address(marketManagerIsolated),
            address(positionManager)
        );
    }

    /// @notice Test that removing a non-existent position manager fails
    function test_removePositionManager_fail_notAdded() public {
        // Deploy a new position manager that was never added
        SimplePositionManager notAddedPM = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            WMON_ADDRESS
        );

        // Try to remove position manager that was never added
        vm.prank(manager);
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        protocolManager.removePositionManager(address(marketManagerIsolated), address(notAddedPM));
    }

    /// @notice Test that removing same position manager twice fails
    function test_removePositionManager_fail_alreadyRemoved() public {
        // Remove position manager first time
        vm.prank(manager);
        protocolManager.removePositionManager(address(marketManagerIsolated), address(positionManager));
        assertFalse(marketManagerIsolated.isPositionManager(address(positionManager)));

        // Try to remove same position manager again - should revert
        vm.prank(manager);
        vm.expectRevert(MarketManagerIsolated.MarketManager__InvalidParameter.selector);
        protocolManager.removePositionManager(address(marketManagerIsolated), address(positionManager));
    }

    /// @notice Verify permission flags are correctly set
    function test_removePositionManager_verifyPermissions() public view {
        assertTrue(protocolManager.canModifyPositionManagers(), "canModifyPositionManagers should be true");
    }
}

