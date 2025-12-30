// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.setCollateralizationPaused
/// @dev The manager (protocolManager address) calls setCollateralizationPaused to pause/unpause
///      collateralization for a specific cToken on a MarketManagerIsolated contract.
///      Note: Both the marketManager AND the cToken must have authority.
contract TestProtocolManagerSetCollateralizationPaused is TestProtocolManagerBase {

    address public manager;

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");

        // Deploy ProtocolManager with both the MarketManager AND the cToken as managed addresses
        // setCollateralizationPaused uses _checkAuthorityAndAsset which requires both to have authority
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](2);
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

        // Grant ProtocolManager market permissions so it can call setCollateralizationPaused
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of collateralization for a cToken
    function test_setCollateralizationPaused_success_pause() public {
        // Verify collateralization is not paused initially
        (, bool collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(collateralizationPaused, "Collateralization should be unpaused initially");

        vm.prank(manager);
        protocolManager.setCollateralizationPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );

        // Verify collateralization is now paused
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should be paused");
    }

    /// @notice Test successful unpausing of collateralization for a cToken
    function test_setCollateralizationPaused_success_unpause() public {
        // First pause collateralization
        vm.prank(manager);
        protocolManager.setCollateralizationPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
        (, bool collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setCollateralizationPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            false
        );

        // Verify collateralization is unpaused
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(collateralizationPaused, "Collateralization should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setCollateralizationPaused_success_toggleMultipleTimes() public {
        bool collateralizationPaused;

        // Pause
        vm.prank(manager);
        protocolManager.setCollateralizationPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused);

        // Unpause
        vm.prank(manager);
        protocolManager.setCollateralizationPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), false);
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(collateralizationPaused);

        // Pause again
        vm.prank(manager);
        protocolManager.setCollateralizationPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused);
    }

    /// @notice Test that pausing different cTokens works independently
    function test_setCollateralizationPaused_success_independentTokens() public {
        // Add authority for second token
        address[] memory additionalAddresses = new address[](1);
        additionalAddresses[0] = address(borrowableCWMON);

        ProtocolManager.PeriodAdjustmentLimits[] memory additionalLimits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        additionalLimits[0] = _getValidLimits();

        // DAO adds authority for the second token
        protocolManager.updateManagementConfig(additionalAddresses, additionalLimits, true);

        // Pause only USDC collateralization
        vm.prank(manager);
        protocolManager.setCollateralizationPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);

        // Verify USDC is paused but WMON is not
        (, bool usdcCollPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        (, bool wmonCollPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(usdcCollPaused, "USDC collateralization should be paused");
        assertFalse(wmonCollPaused, "WMON collateralization should still be unpaused");

        // Now pause WMON too
        vm.prank(manager);
        protocolManager.setCollateralizationPaused(address(marketManagerIsolated), address(borrowableCWMON), true);

        (, wmonCollPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(wmonCollPaused, "WMON collateralization should be paused");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setCollateralizationPaused
    function test_setCollateralizationPaused_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setCollateralizationPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that manager cannot pause without market authority
    function test_setCollateralizationPaused_fail_noMarketAuthority() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setCollateralizationPaused(
            unauthorizedMarket,
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that manager cannot pause without cToken authority
    function test_setCollateralizationPaused_fail_noCTokenAuthority() public {
        // borrowableCWMON is not in the managed addresses, only borrowableCUSDC_MONAD is
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setCollateralizationPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON), // No authority for this token
            true
        );
    }

    /// @notice Test that setCollateralizationPaused fails when canModifyCollateralizationStatus is false
    function test_setCollateralizationPaused_fail_canModifyCollateralizationStatusDisabled() public {
        // Deploy ProtocolManager with canModifyCollateralizationStatus = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
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
        restrictedPM.setCollateralizationPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setCollateralizationPaused_fail_cannotUnpause() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

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
        noUnpausePM.setCollateralizationPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (, bool collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setCollateralizationPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), false);

        // Verify still paused
        (, collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setCollateralizationPaused_success_pauseWhenCanUnpauseFalse() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

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
        noUnpausePM.setCollateralizationPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);

        (, bool collateralizationPaused, ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(collateralizationPaused, "Collateralization should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setCollateralizationPaused_verifyPermissions() public view {
        assertTrue(protocolManager.canModifyCollateralizationStatus(), "canModifyCollateralizationStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }
}

