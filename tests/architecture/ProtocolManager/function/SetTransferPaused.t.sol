// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.setTransferPaused
/// @dev The manager (protocolManager address) calls setTransferPaused to pause/unpause
///      transfers on a MarketManagerIsolated contract.
contract TestProtocolManagerSetTransferPaused is TestProtocolManagerBase {

    address public manager;

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");

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

        // Grant ProtocolManager market permissions so it can call setTransferPaused
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of transfers
    function test_setTransferPaused_success_pause() public {
        // Verify transfer is not paused initially (1 = unpaused)
        assertEq(marketManagerIsolated.transferPaused(), 1, "Transfer should be unpaused initially");

        vm.prank(manager);
        protocolManager.setTransferPaused(address(marketManagerIsolated), true);

        // Verify transfer is now paused (2 = paused)
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should be paused");
    }

    /// @notice Test successful unpausing of transfers
    function test_setTransferPaused_success_unpause() public {
        // First pause transfers
        vm.prank(manager);
        protocolManager.setTransferPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setTransferPaused(address(marketManagerIsolated), false);

        // Verify transfer is unpaused (1 = unpaused)
        assertEq(marketManagerIsolated.transferPaused(), 1, "Transfer should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setTransferPaused_success_toggleMultipleTimes() public {
        // Pause
        vm.prank(manager);
        protocolManager.setTransferPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.transferPaused(), 2);

        // Unpause
        vm.prank(manager);
        protocolManager.setTransferPaused(address(marketManagerIsolated), false);
        assertEq(marketManagerIsolated.transferPaused(), 1);

        // Pause again
        vm.prank(manager);
        protocolManager.setTransferPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.transferPaused(), 2);
    }

    /// @notice Test that pausing an already paused market is idempotent
    function test_setTransferPaused_success_pauseWhenAlreadyPaused() public {
        // Pause
        vm.prank(manager);
        protocolManager.setTransferPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.transferPaused(), 2);

        // Pause again - should succeed and remain paused
        vm.prank(manager);
        protocolManager.setTransferPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.transferPaused(), 2);
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setTransferPaused
    function test_setTransferPaused_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setTransferPaused(address(marketManagerIsolated), true);
    }

    /// @notice Test that manager cannot pause a market without authority
    function test_setTransferPaused_fail_noAuthority() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setTransferPaused(unauthorizedMarket, true);
    }

    /// @notice Test that setTransferPaused fails when canModifyTransferStatus is false
    function test_setTransferPaused_fail_canModifyTransferStatusDisabled() public {
        // Deploy ProtocolManager with canModifyTransferStatus = false
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
            canModifyTransferStatus: false, // Disabled
            canModifyPositionManagers: true
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

        // Verify canModifyTransferStatus is false
        assertFalse(restrictedPM.canModifyTransferStatus(), "canModifyTransferStatus should be false");

        // Try to pause - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.setTransferPaused(address(marketManagerIsolated), true);
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setTransferPaused_fail_cannotUnpause() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canModifyTokenConfig: true,
            canModifyIRM: true,
            canUnpause: false, // Cannot unpause
            canModifyMintStatus: true,
            canModifyCollateralizationStatus: true,
            canModifyBorrowStatus: true,
            canModifyLiquidationStatus: true,
            canModifyRedeemStatus: true,
            canModifyTransferStatus: true,
            canModifyPositionManagers: true
        });

        ProtocolManager noUnpausePM = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            noUnpausePerms,
            managedAddresses,
            limits
        );

        // Grant market permissions
        centralRegistry.addMarketPermissions(address(noUnpausePM));

        // First pause - this should work
        vm.prank(manager);
        noUnpausePM.setTransferPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setTransferPaused(address(marketManagerIsolated), false);

        // Verify still paused
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setTransferPaused_success_pauseWhenCanUnpauseFalse() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canModifyTokenConfig: true,
            canModifyIRM: true,
            canUnpause: false, // Cannot unpause, but can still pause
            canModifyMintStatus: true,
            canModifyCollateralizationStatus: true,
            canModifyBorrowStatus: true,
            canModifyLiquidationStatus: true,
            canModifyRedeemStatus: true,
            canModifyTransferStatus: true,
            canModifyPositionManagers: true
        });

        ProtocolManager noUnpausePM = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            noUnpausePerms,
            managedAddresses,
            limits
        );

        // Grant market permissions
        centralRegistry.addMarketPermissions(address(noUnpausePM));

        // Pause should work even with canUnpause = false
        vm.prank(manager);
        noUnpausePM.setTransferPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setTransferPaused_verifyPermissions() public view {
        assertTrue(protocolManager.canModifyTransferStatus(), "canModifyTransferStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }
}

