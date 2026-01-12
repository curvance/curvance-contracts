// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.setBorrowPaused
/// @dev The manager (protocolManager address) calls setBorrowPaused to pause/unpause
///      borrowing for a specific cToken on a MarketManagerIsolated contract.
///      Note: Both the marketManager AND the cToken must have authority.
contract TestProtocolManagerSetBorrowPaused is TestProtocolManagerBase {

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

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of borrowing for a cToken
    function test_setBorrowPaused_success_pause() public {
        // Verify borrowing is not paused initially
        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(borrowPaused, "Borrow should be unpaused initially");

        vm.prank(manager);
        protocolManager.setBorrowPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );

        // Verify borrowing is now paused
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should be paused");
    }

    /// @notice Test successful unpausing of borrowing for a cToken
    function test_setBorrowPaused_success_unpause() public {
        // First pause borrowing
        vm.prank(manager);
        protocolManager.setBorrowPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setBorrowPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            false
        );

        // Verify borrowing is unpaused
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(borrowPaused, "Borrow should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setBorrowPaused_success_toggleMultipleTimes() public {
        bool borrowPaused;

        // Pause
        vm.prank(manager);
        protocolManager.setBorrowPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused);

        // Unpause
        vm.prank(manager);
        protocolManager.setBorrowPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), false);
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(borrowPaused);

        // Pause again
        vm.prank(manager);
        protocolManager.setBorrowPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused);
    }

    /// @notice Test that pausing different cTokens works independently
    function test_setBorrowPaused_success_independentTokens() public {
        // Add authority for second token
        address[] memory additionalAddresses = new address[](1);
        additionalAddresses[0] = address(borrowableCWMON);

        ProtocolManager.PeriodLimits[] memory additionalLimits = new ProtocolManager.PeriodLimits[](1);
        additionalLimits[0] = _getValidLimits();

        // DAO adds authority for the second token
        protocolManager.updateManagementConfig(additionalAddresses, additionalLimits, true);

        // Pause only USDC borrowing
        vm.prank(manager);
        protocolManager.setBorrowPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);

        // Verify USDC is paused but WMON is not
        (, , bool usdcBorrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        (, , bool wmonBorrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(usdcBorrowPaused, "USDC borrow should be paused");
        assertFalse(wmonBorrowPaused, "WMON borrow should still be unpaused");

        // Now pause WMON too
        vm.prank(manager);
        protocolManager.setBorrowPaused(address(marketManagerIsolated), address(borrowableCWMON), true);

        (, , wmonBorrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(wmonBorrowPaused, "WMON borrow should be paused");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setBorrowPaused
    function test_setBorrowPaused_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setBorrowPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that manager cannot pause without market authority
    function test_setBorrowPaused_fail_noMarketAuthority() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setBorrowPaused(
            unauthorizedMarket,
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that manager cannot pause without cToken authority
    function test_setBorrowPaused_fail_noCTokenAuthority() public {
        // borrowableCWMON is not in the managed addresses, only borrowableCUSDC_MONAD is
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setBorrowPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON), // No authority for this token
            true
        );
    }

    /// @notice Test that setBorrowPaused fails when canModifyBorrowStatus is false
    function test_setBorrowPaused_fail_canModifyBorrowStatusDisabled() public {
        // Deploy ProtocolManager with canModifyBorrowStatus = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
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
        restrictedPM.setBorrowPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setBorrowPaused_fail_cannotUnpause() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
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
        noUnpausePM.setBorrowPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setBorrowPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), false);

        // Verify still paused
        (, , borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setBorrowPaused_success_pauseWhenCanUnpauseFalse() public {
        // Deploy ProtocolManager with canUnpause = false
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
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
        noUnpausePM.setBorrowPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);

        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(borrowPaused, "Borrow should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setBorrowPaused_verifyPermissions() public view {
        assertTrue(protocolManager.canModifyBorrowStatus(), "canModifyBorrowStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }
}

