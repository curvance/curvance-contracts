// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.setMintPaused
/// @dev The manager (protocolManager address) calls setMintPaused to pause/unpause
///      minting for a specific cToken on a MarketManagerIsolated contract.
///      Note: Both the marketManager AND the cToken must have authority.
contract TestProtocolManagerSetMintPaused is TestProtocolManagerBase {

    address public manager;

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");

        // Deploy ProtocolManager with both the MarketManager AND the cToken as managed addresses
        // setMintPaused uses _checkAuthorityAndAsset which requires both to have authority
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

        // Grant ProtocolManager market permissions so it can call setMintPaused
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful pausing of minting for a cToken
    function test_setMintPaused_success_pause() public {
        // Verify minting is not paused initially
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(mintPaused, "Mint should be unpaused initially");

        vm.prank(manager);
        protocolManager.setMintPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );

        // Verify minting is now paused
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should be paused");
    }

    /// @notice Test successful unpausing of minting for a cToken
    function test_setMintPaused_success_unpause() public {
        // First pause minting
        vm.prank(manager);
        protocolManager.setMintPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should be paused");

        // Now unpause
        vm.prank(manager);
        protocolManager.setMintPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            false
        );

        // Verify minting is unpaused
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(mintPaused, "Mint should be unpaused");
    }

    /// @notice Test pausing and unpausing multiple times
    function test_setMintPaused_success_toggleMultipleTimes() public {
        bool mintPaused;

        // Pause
        vm.prank(manager);
        protocolManager.setMintPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused);

        // Unpause
        vm.prank(manager);
        protocolManager.setMintPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), false);
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(mintPaused);

        // Pause again
        vm.prank(manager);
        protocolManager.setMintPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused);
    }

    /// @notice Test that pausing different cTokens works independently
    function test_setMintPaused_success_independentTokens() public {
        // Add authority for second token
        address[] memory additionalAddresses = new address[](1);
        additionalAddresses[0] = address(borrowableCWMON);

        ProtocolManager.PeriodLimits[] memory additionalLimits = new ProtocolManager.PeriodLimits[](1);
        additionalLimits[0] = _getValidLimits();

        // DAO adds authority for the second token
        // Note: address(this) already has elevated permissions from test setup
        protocolManager.updateManagementConfig(additionalAddresses, additionalLimits, true);

        // Pause only USDC minting
        vm.prank(manager);
        protocolManager.setMintPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);

        // Verify USDC is paused but WMON is not
        (bool usdcMintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        (bool wmonMintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(usdcMintPaused, "USDC mint should be paused");
        assertFalse(wmonMintPaused, "WMON mint should still be unpaused");

        // Now pause WMON too
        vm.prank(manager);
        protocolManager.setMintPaused(address(marketManagerIsolated), address(borrowableCWMON), true);

        (wmonMintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(wmonMintPaused, "WMON mint should be paused");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call setMintPaused
    function test_setMintPaused_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setMintPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that manager cannot pause without market authority
    function test_setMintPaused_fail_noMarketAuthority() public {
        address unauthorizedMarket = makeAddr("unauthorizedMarket");

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setMintPaused(
            unauthorizedMarket,
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that manager cannot pause without cToken authority
    function test_setMintPaused_fail_noCTokenAuthority() public {
        // borrowableCWMON is not in the managed addresses, only borrowableCUSDC_MONAD is
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setMintPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON), // No authority for this token
            true
        );
    }

    /// @notice Test that setMintPaused fails when canModifyMintStatus is false
    function test_setMintPaused_fail_canModifyMintStatusDisabled() public {
        // Deploy ProtocolManager with canModifyMintStatus = false
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
        restrictedPM.setMintPaused(
            address(marketManagerIsolated),
            address(borrowableCUSDC_MONAD),
            true
        );
    }

    /// @notice Test that unpause fails when canUnpause is false
    function test_setMintPaused_fail_cannotUnpause() public {
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
        noUnpausePM.setMintPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should be paused");

        // Try to unpause - should fail because canUnpause is false
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        noUnpausePM.setMintPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), false);

        // Verify still paused
        (mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should still be paused");
    }

    /// @notice Test that pausing still works when canUnpause is false
    function test_setMintPaused_success_pauseWhenCanUnpauseFalse() public {
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
        noUnpausePM.setMintPaused(address(marketManagerIsolated), address(borrowableCUSDC_MONAD), true);

        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused, "Mint should be paused");
    }

    /// @notice Verify permission flags are correctly set
    function test_setMintPaused_verifyPermissions() public view {
        assertTrue(protocolManager.canModifyMintStatus(), "canModifyMintStatus should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
    }
}

