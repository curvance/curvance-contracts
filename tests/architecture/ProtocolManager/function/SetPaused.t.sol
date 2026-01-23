// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.setBorrowPaused
/// @dev The manager (protocolManager address) calls setBorrowPaused to pause/unpause
///      borrowing for a specific cToken on a MarketManagerIsolated contract.
///      Note: Both the marketManager AND the cToken must have authority.
contract TestProtocolManagerSetPaused is TestProtocolManagerBase {

    address public manager;

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");

        // Deploy ProtocolManager with both the MarketManager AND the cToken as managed addresses
        // setBorrowPaused uses _checkAuthorityAndAsset which requires both to have authority
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

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

        // Grant ProtocolManager market permissions so it can call setBorrowPaused
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SET LIQUIDATION PAUSED TESTS ///

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of liquidations
    function test_setPaused_success_pauseLiquidation() public {
        // Verify liquidation is not paused initially (1 = unpaused)
        assertEq(marketManagerIsolated.liquidationPaused(), 1, "Liquidation should be unpaused initially");

        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);

        // Verify liquidation is now paused (2 = paused)
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should be paused");
    }

    /// @notice Test successful unpausing of liquidations
    function test_setPaused_success_unpauseLiquidation() public {
        // First pause liquidations
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, false);

        // Verify liquidation is unpaused (1 = unpaused)
        assertEq(marketManagerIsolated.liquidationPaused(), 1, "Liquidation should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setPaused_success_toggleMultipleTimesLiquidation() public {
        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2);

        // Unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, false);
        assertEq(marketManagerIsolated.liquidationPaused(), 1);

        // Pause again
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2);
    }

    /// @notice Test that pausing an already paused market is idempotent
    function test_setPaused_success_pauseWhenAlreadyPausedLiquidation() public {
        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2);

        // Pause again - should succeed and remain paused
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2);
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setLiquidationPaused
    function test_setPaused_fail_notManager_Liquidation() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
    }

    /// @notice Test that manager cannot pause a market without authority
    function test_setLiquidationPaused_fail_noAuthority() public {
        // Deploy a new MarketManager that doesn't have authority
        // We'll use a mock address since we just need to test the authority check
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(unauthorizedMarket, address(borrowableCUSDC_MONAD), 0, true);
    }

    /// @notice Test that setLiquidationPaused fails when canModifyLiquidationStatus is false
    function test_setPaused_fail_canModifyLiquidationStatusDisabled_Liquidation() public {
        // Deploy ProtocolManager with canModifyLiquidationStatus = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        restrictedPM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setPaused_fail_cannotUnpause_Liquidation() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, false);

        // Verify still paused
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setPaused_success_pauseWhenCanUnpauseFalse_Liquidation() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 0, true);
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "Liquidation should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setPaused_verifyPermissions_Liquidation() public view {
        assertTrue(protocolManager.canModifyLiquidationStatus(), "canModifyLiquidationStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }

    /// SET REDEEM PAUSED TESTS ///

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of redemptions
    function test_setPaused_success_pauseRedeem() public {
        // Verify redemption is not paused initially (1 = unpaused)
        assertEq(marketManagerIsolated.redeemPaused(), 1, "Redeem should be unpaused initially");

        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);

        // Verify redemption is now paused (2 = paused)
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should be paused");
    }

    /// @notice Test successful unpausing of redemptions
    function test_setPaused_success_unpauseRedeem() public {
        // First pause redemptions
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, false);

        // Verify redemption is unpaused (1 = unpaused)
        assertEq(marketManagerIsolated.redeemPaused(), 1, "Redeem should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setPaused_success_toggleMultipleTimesRedeem() public {
        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
        assertEq(marketManagerIsolated.redeemPaused(), 2);

        // Unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, false);
        assertEq(marketManagerIsolated.redeemPaused(), 1);

        // Pause again
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
        assertEq(marketManagerIsolated.redeemPaused(), 2);
    }

    /// @notice Test that pausing an already paused market is idempotent
    function test_setPaused_success_pauseWhenAlreadyPausedRedeem() public {
        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
        assertEq(marketManagerIsolated.redeemPaused(), 2);

        // Pause again - should succeed and remain paused
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
        assertEq(marketManagerIsolated.redeemPaused(), 2);
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setRedeemPaused
    function test_setPaused_fail_notManager_Redeem() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
    }

    /// @notice Test that manager cannot pause a market without authority
    function test_setPaused_fail_noAuthority_Redeem() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(unauthorizedMarket, address(borrowableCUSDC_MONAD), 1, true);
    }

    /// @notice Test that setRedeemPaused fails when canModifyRedeemStatus is false
    function test_setPaused_fail_canModifyRedeemStatusDisabled_Redeem() public {
        // Deploy ProtocolManager with canModifyRedeemStatus = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        restrictedPM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setPaused_fail_cannotUnpause_Redeem() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, false);

        // Verify still paused
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setPaused_success_pauseWhenCanUnpauseFalse_Redeem() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 1, true);
        assertEq(marketManagerIsolated.redeemPaused(), 2, "Redeem should be paused");
    }

    /// SET TRANSFER PAUSED TESTS ///

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of transfers
    function test_setPaused_success_pauseTransfer() public {
        // Verify transfer is not paused initially (1 = unpaused)
        assertEq(marketManagerIsolated.transferPaused(), 1, "Transfer should be unpaused initially");

        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);

        // Verify transfer is now paused (2 = paused)
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should be paused");
    }

    /// @notice Test successful unpausing of transfers
    function test_setPaused_success_unpauseTransfer() public {
        // First pause transfers
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, false);

        // Verify transfer is unpaused (1 = unpaused)
        assertEq(marketManagerIsolated.transferPaused(), 1, "Transfer should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setPaused_success_toggleMultipleTimesTransfer() public {
        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
        assertEq(marketManagerIsolated.transferPaused(), 2);

        // Unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, false);
        assertEq(marketManagerIsolated.transferPaused(), 1);

        // Pause again
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
        assertEq(marketManagerIsolated.transferPaused(), 2);
    }

    /// @notice Test that pausing an already paused market is idempotent
    function test_setPaused_success_pauseWhenAlreadyPausedTransfer() public {
        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
        assertEq(marketManagerIsolated.transferPaused(), 2);

        // Pause again - should succeed and remain paused
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
        assertEq(marketManagerIsolated.transferPaused(), 2);
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setTransferPaused
    function test_setPaused_fail_notManager_Transfer() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
    }

    /// @notice Test that manager cannot pause a market without authority
    function test_setPaused_fail_noAuthority_Transfer() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(unauthorizedMarket, address(borrowableCUSDC_MONAD), 2, true);
    }

    /// @notice Test that setTransferPaused fails when canModifyTransferStatus is false
    function test_setPaused_fail_canModifyTransferStatusDisabled_Transfer() public {
        // Deploy ProtocolManager with canModifyTransferStatus = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        restrictedPM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setPaused_fail_cannotUnpause_Transfer() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, false);

        // Verify still paused
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setPaused_success_pauseWhenCanUnpauseFalse_Transfer() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(marketManagerIsolated);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 2, true);
        assertEq(marketManagerIsolated.transferPaused(), 2, "Transfer should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setPaused_verifyPermissions_Transfer() public view {
        assertTrue(protocolManager.canModifyTransferStatus(), "canModifyTransferStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }

    /// SET MINT PAUSED TESTS ///

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of minting for a cToken
    function test_setPaused_success_pauseMint() public {
        // Verify minting is not paused initially
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(mintPaused, "Mint should be unpaused initially");

        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            3,
            true
        );

        // Verify minting is now paused
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should be paused");
    }

    /// @notice Test successful unpausing of minting for a cToken
    function test_setPaused_success_unpauseMint() public {
        // First pause minting
        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            3,
            true
        );
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            3,
            false
        );

        // Verify minting is unpaused
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(mintPaused, "Mint should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setPaused_success_toggleMultipleTimesMint() public {
        bool mintPaused;

        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 3, true);
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused);

        // Unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 3, false);
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(mintPaused);

        // Pause again
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 3, true);
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused);
    }

    /// @notice Test that pausing different cTokens works independently
    function test_setPaused_success_independentTokensMint() public {
        // Add authority for second token
        address[] memory additionalAddresses = new address[](1);
        additionalAddresses[0] = address(borrowableCWMON);

        ProtocolManager.PeriodLimits[] memory additionalLimits = new ProtocolManager.PeriodLimits[](1);
        additionalLimits[0] = _getValidLimits();

        // Warp to valid time window for updateManagementConfig
        _warpToValidManagementConfigWindow();

        // DAO adds authority for the second token
        protocolManager.updateManagementConfig(additionalAddresses, additionalLimits, true);

        // Pause only USDC minting
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 3, true);

        // Verify USDC is paused but WMON is not
        (bool usdcMintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        (bool wmonMintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(usdcMintPaused, "USDC mint should be paused");
        assertFalse(wmonMintPaused, "WMON mint should still be unpaused");

        // Now pause WMON too
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCWMON), 3, true);

        (wmonMintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(wmonMintPaused, "WMON mint should be paused");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setMintPaused
    function test_setPaused_fail_notManager_Mint() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            3,
            true
        );
    }

    /// @notice Test that manager cannot pause without market authority
    function test_setPaused_fail_noMarketAuthority_Mint() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            unauthorizedMarket,
            address(borrowableCUSDC_MONAD),
            3,
            true
        );
    }

    /// @notice Test that manager cannot pause without cToken authority
    function test_setPaused_fail_noCTokenAuthority_Mint() public {
        // borrowableCWMON is not in the managed addresses, only borrowableCUSDC_MONAD is
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON), // No authority for this token
            3,
            true
        );
    }

    /// @notice Test that setMintPaused fails when canModifyMintStatus is false
    function test_setPaused_fail_canModifyMintStatusDisabled_Mint() public {
        // Deploy ProtocolManager with canModifyMintStatus = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
            canModifyTokenConfig: true,
            canModifyIRM: true,
            canUnpause: true,
            canModifyMintStatus: false, // Disabled
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
            restrictedPerms,
            managedAddresses,
            limits
        );

        // Grant market permissions
        centralRegistry.addMarketPermissions(address(restrictedPM));

        // Verify canModifyMintStatus is false
        assertFalse(restrictedPM.canModifyMintStatus(), "canModifyMintStatus should be false");

        // Try to pause - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            3,
            true
        );
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setPaused_fail_cannotUnpause_Mint() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 3, true);
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 3, false);

        // Verify still paused
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setPaused_success_pauseWhenCanUnpauseFalse_Mint() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 3, true);

        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setPaused_verifyPermissions_Mint() public view {
        assertTrue(protocolManager.canModifyMintStatus(), "canModifyMintStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }

    // SET COLLATERALIZATION PAUSED TESTS ///

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of collateralization for a cToken
    function test_setPaused_success_pauseCollateralization() public {
        // Verify collateralization is not paused initially
        (, bool collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(collateralizationPaused, "Collateralization should be unpaused initially");

        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            4,
            true
        );

        // Verify collateralization is now paused
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should be paused");
    }

    /// @notice Test successful unpausing of collateralization for a cToken
    function test_setPaused_success_unpauseCollateralization() public {
        // First pause collateralization
        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            4,
            true
        );
        (, bool collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            4,
            false
        );

        // Verify collateralization is unpaused
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(collateralizationPaused, "Collateralization should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setPaused_success_toggleMultipleTimesCollateralization() public {
        bool collateralizationPaused;

        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 4, true);
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused);

        // Unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 4, false);
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(collateralizationPaused);

        // Pause again
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 4, true);
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused);
    }

    /// @notice Test that pausing different cTokens works independently
    function test_setPaused_success_independentTokensCollateralization() public {
        // Add authority for second token
        address[] memory additionalAddresses = new address[](1);
        additionalAddresses[0] = address(borrowableCWMON);

        ProtocolManager.PeriodLimits[] memory additionalLimits = new ProtocolManager.PeriodLimits[](1);
        additionalLimits[0] = _getValidLimits();

        // Warp to valid time window for updateManagementConfig
        _warpToValidManagementConfigWindow();

        // DAO adds authority for the second token
        protocolManager.updateManagementConfig(additionalAddresses, additionalLimits, true);

        // Pause only USDC collateralization
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 4, true);

        // Verify USDC is paused but WMON is not
        (, bool usdcCollPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        (, bool wmonCollPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(usdcCollPaused, "USDC collateralization should be paused");
        assertFalse(wmonCollPaused, "WMON collateralization should still be unpaused");

        // Now pause WMON too
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCWMON), 4, true);

        (, wmonCollPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(wmonCollPaused, "WMON collateralization should be paused");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setCollateralizationPaused
    function test_setPaused_fail_notManager_Collateralization() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            4,
            true
        );
    }

    /// @notice Test that manager cannot pause without market authority
    function test_setPaused_fail_noMarketAuthority_Collateralization() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            unauthorizedMarket,
            address(borrowableCUSDC_MONAD),
            4,
            true
        );
    }

    /// @notice Test that manager cannot pause without cToken authority
    function test_setPaused_fail_noCTokenAuthority_Collateralization() public {
        // borrowableCWMON is not in the managed addresses, only borrowableCUSDC_MONAD is
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON), // No authority for this token
            4,
            true
        );
    }

    /// @notice Test that setCollateralizationPaused fails when canModifyCollateralizationStatus is false
    function test_setPaused_fail_canModifyCollateralizationStatusDisabled_Collateralization() public {
        // Deploy ProtocolManager with canModifyCollateralizationStatus = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
            canModifyTokenConfig: true,
            canModifyIRM: true,
            canUnpause: true,
            canModifyMintStatus: true,
            canModifyCollateralizationStatus: false, // Disabled
            canModifyBorrowStatus: true,
            canModifyLiquidationStatus: true,
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

        // Verify canModifyCollateralizationStatus is false
        assertFalse(restrictedPM.canModifyCollateralizationStatus(), "canModifyCollateralizationStatus should be false");

        // Try to pause - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            4,
            true
        );
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setPaused_fail_cannotUnpause_Collateralization() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 4, true);
        (, bool collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 4, false);

        // Verify still paused
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setPaused_success_pauseWhenCanUnpauseFalse_Collateralization() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 4, true);

        (, bool collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setPaused_verifyPermissions_Collateralization() public view {
        assertTrue(protocolManager.canModifyCollateralizationStatus(), "canModifyCollateralizationStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }

    /// SET BORROW PAUSED TESTS ///

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of borrowing for a cToken
    function test_setPaused_success_pauseBorrow() public {
        // Verify borrowing is not paused initially
        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(borrowPaused, "Borrow should be unpaused initially");

        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            5,
            true
        );

        // Verify borrowing is now paused
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should be paused");
    }

    /// @notice Test successful unpausing of borrowing for a cToken
    function test_setPaused_success_unpauseBorrow() public {
        // First pause borrowing
        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            5,
            true
        );
        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            5,
            false
        );

        // Verify borrowing is unpaused
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(borrowPaused, "Borrow should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setPaused_success_toggleMultipleTimesBorrow() public {
        bool borrowPaused;

        // Pause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 5, true);
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused);

        // Unpause
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 5, false);
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(borrowPaused);

        // Pause again
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 5, true);
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused);
    }

    /// @notice Test that pausing different cTokens works independently
    function test_setPaused_success_independentTokensBorrow() public {
        // Add authority for second token
        address[] memory additionalAddresses = new address[](1);
        additionalAddresses[0] = address(borrowableCWMON);

        ProtocolManager.PeriodLimits[] memory additionalLimits = new ProtocolManager.PeriodLimits[](1);
        additionalLimits[0] = _getValidLimits();

        // Warp to valid time window for updateManagementConfig
        _warpToValidManagementConfigWindow();

        // DAO adds authority for the second token
        protocolManager.updateManagementConfig(additionalAddresses, additionalLimits, true);

        // Pause only USDC borrowing
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 5, true);

        // Verify USDC is paused but WMON is not
        (, , bool usdcBorrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        (, , bool wmonBorrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(usdcBorrowPaused, "USDC borrow should be paused");
        assertFalse(wmonBorrowPaused, "WMON borrow should still be unpaused");

        // Now pause WMON too
        vm.prank(manager);
        protocolManager.setPaused(address(marketManagerIsolated), address(borrowableCWMON), 5, true);

        (, , wmonBorrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(wmonBorrowPaused, "WMON borrow should be paused");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setBorrowPaused
    function test_setPaused_fail_notManager_Borrow() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            5,
            true
        );
    }

    /// @notice Test that manager cannot pause without market authority
    function test_setPaused_fail_noMarketAuthority_Borrow() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            unauthorizedMarket,
            address(borrowableCUSDC_MONAD),
            5,
            true
        );
    }

    /// @notice Test that manager cannot pause without cToken authority
    function test_setPaused_fail_noCTokenAuthority_Borrow() public {
        // borrowableCWMON is not in the managed addresses, only borrowableCUSDC_MONAD is
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON), // No authority for this token
            5,
            true
        );
    }

    /// @notice Test that setBorrowPaused fails when canModifyBorrowStatus is false
    function test_setPaused_fail_canModifyBorrowStatusDisabled_Borrow() public {
        // Deploy ProtocolManager with canModifyBorrowStatus = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
            canModifyTokenConfig: true,
            canModifyIRM: true,
            canUnpause: true,
            canModifyMintStatus: true,
            canModifyCollateralizationStatus: true,
            canModifyBorrowStatus: false, // Disabled
            canModifyLiquidationStatus: true,
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

        // Verify canModifyBorrowStatus is false
        assertFalse(restrictedPM.canModifyBorrowStatus(), "canModifyBorrowStatus should be false");

        // Try to pause - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.setPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            5,
            true
        );
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setPaused_fail_cannotUnpause_Borrow() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 5, true);
        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 5, false);

        // Verify still paused
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setPaused_success_pauseWhenCanUnpauseFalse_Borrow() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory noUnpausePerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canDisablePriceGuards: true,
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
        noUnpausePM.setPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), 5, true);

        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setPaused_verifyPermissions_Borrow() public view {
        assertTrue(protocolManager.canModifyBorrowStatus(), "canModifyBorrowStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }
}

