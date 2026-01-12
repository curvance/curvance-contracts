// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

/// @notice Tests for ProtocolManager.setLiquidationPaused
/// @dev The manager (protocolManager address) calls setLiquidationPaused to pause/unpause
///      liquidations on a MarketManagerIsolated contract.
contract TestProtocolManagerSetLiquidationPaused is TestProtocolManagerBase {

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

        // Grant ProtocolManager market permissions so it can call setLiquidationPaused
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of liquidations
    function test_setLiquidationPaused_success_pause() public {
        // Verify liquidation is not paused initially (1 = unpaused)
        assertEq(marketManagerIsolated.liquidationPaused(), 1, "Liquidation should be unpaused initially");

        vm.prank(manager);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), true);

        // Verify liquidation is now paused (2 = paused)
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should be paused");
    }

    /// @notice Test successful unpausing of liquidations
    function test_setLiquidationPaused_success_unpause() public {
        // First pause liquidations
        vm.prank(manager);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), false);

        // Verify liquidation is unpaused (1 = unpaused)
        assertEq(marketManagerIsolated.liquidationPaused(), 1, "Liquidation should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setLiquidationPaused_success_toggleMultipleTimes() public {
        // Pause
        vm.prank(manager);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2);

        // Unpause
        vm.prank(manager);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), false);
        assertEq(marketManagerIsolated.liquidationPaused(), 1);

        // Pause again
        vm.prank(manager);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2);
    }

    /// @notice Test that pausing an already paused market is idempotent
    function test_setLiquidationPaused_success_pauseWhenAlreadyPaused() public {
        // Pause
        vm.prank(manager);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2);

        // Pause again - should succeed and remain paused
        vm.prank(manager);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2);
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setLiquidationPaused
    function test_setLiquidationPaused_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setLiquidationPaused(address(marketManagerIsolated), true);
    }

    /// @notice Test that manager cannot pause a market without authority
    function test_setLiquidationPaused_fail_noAuthority() public {
        // Deploy a new MarketManager that doesn't have authority
        // We'll use a mock address since we just need to test the authority check
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setLiquidationPaused(unauthorizedMarket, true);
    }

    /// @notice Test that setLiquidationPaused fails when canModifyLiquidationStatus is false
    function test_setLiquidationPaused_fail_canModifyLiquidationStatusDisabled() public {
        // Deploy ProtocolManager with canModifyLiquidationStatus = false
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
            canModifyLiquidationStatus: false, // Disabled
            canModifyRedeemStatus: true,
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

        // Verify canModifyLiquidationStatus is false
        assertFalse(restrictedPM.canModifyLiquidationStatus(), "canModifyLiquidationStatus should be false");

        // Try to pause - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.setLiquidationPaused(address(marketManagerIsolated), true);
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setLiquidationPaused_fail_cannotUnpause() public {
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
        noUnpausePM.setLiquidationPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setLiquidationPaused(address(marketManagerIsolated), false);

        // Verify still paused
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setLiquidationPaused_success_pauseWhenCanUnpauseFalse() public {
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
        noUnpausePM.setLiquidationPaused(address(marketManagerIsolated), true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setLiquidationPaused_verifyPermissions() public view {
        assertTrue(protocolManager.canModifyLiquidationStatus(), "canModifyLiquidationStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }
}

