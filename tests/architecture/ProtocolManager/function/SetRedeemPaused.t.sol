// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.setRedeemPaused
/// @dev The manager (protocolManager address) calls setRedeemPaused to pause/unpause
///      redemptions on a MarketManagerIsolated contract.
contract TestProtocolManagerSetRedeemPaused is TestProtocolManagerBase {

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

        // Grant ProtocolManager market permissions so it can call setRedeemPaused
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of redemptions
    function test_setRedeemPaused_success_pause() public {
        // Verify redemption is not paused initially (1 = unpaused)
        assertEq(marketManagerIsolated.redeemPaused(), 1, "Redeem should be unpaused initially");

        vm.prank(manager);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), true);

        // Verify redemption is now paused (2 = paused)
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should be paused");
    }

    /// @notice Test successful unpausing of redemptions
    function test_setRedeemPaused_success_unpause() public {
        // First pause redemptions
        vm.prank(manager);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), false);

        // Verify redemption is unpaused (1 = unpaused)
        assertEq(marketManagerIsolated.redeemPaused(), 1, "Redeem should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setRedeemPaused_success_toggleMultipleTimes() public {
        // Pause
        vm.prank(manager);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.redeemPaused(), 2);

        // Unpause
        vm.prank(manager);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), false);
        assertEq(marketManagerIsolated.redeemPaused(), 1);

        // Pause again
        vm.prank(manager);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.redeemPaused(), 2);
    }

    /// @notice Test that pausing an already paused market is idempotent
    function test_setRedeemPaused_success_pauseWhenAlreadyPaused() public {
        // Pause
        vm.prank(manager);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.redeemPaused(), 2);

        // Pause again - should succeed and remain paused
        vm.prank(manager);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.redeemPaused(), 2);
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setRedeemPaused
    function test_setRedeemPaused_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setRedeemPaused(address(marketManagerIsolated), true);
    }

    /// @notice Test that manager cannot pause a market without authority
    function test_setRedeemPaused_fail_noAuthority() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setRedeemPaused(unauthorizedMarket, true);
    }

    /// @notice Test that setRedeemPaused fails when canModifyRedeemStatus is false
    function test_setRedeemPaused_fail_canModifyRedeemStatusDisabled() public {
        // Deploy ProtocolManager with canModifyRedeemStatus = false
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
            canModifyRedeemStatus: false, // Disabled
            canModifyTransferStatus: true,
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

        // Verify canModifyRedeemStatus is false
        assertFalse(restrictedPM.canModifyRedeemStatus(), "canModifyRedeemStatus should be false");

        // Try to pause - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.setRedeemPaused(address(marketManagerIsolated), true);
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setRedeemPaused_fail_cannotUnpause() public {
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
        noUnpausePM.setRedeemPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setRedeemPaused(address(marketManagerIsolated), false);

        // Verify still paused
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setRedeemPaused_success_pauseWhenCanUnpauseFalse() public {
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
        noUnpausePM.setRedeemPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setRedeemPaused_verifyPermissions() public view {
        assertTrue(protocolManager.canModifyRedeemStatus(), "canModifyRedeemStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }
}

