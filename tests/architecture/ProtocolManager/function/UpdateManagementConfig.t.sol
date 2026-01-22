// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

// Notes: DAO calls updateManagementConfig to configure protocol managers.
contract TestProtocolManagerUpdateManagementConfig is TestProtocolManagerBase {

    address public newManagedAddress;

    function setUp() public override {
        super.setUp();
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
        newManagedAddress = makeAddr("newManagedAddress");

        // Warp to valid time window for updateManagementConfig
        _warpToValidManagementConfigWindow();
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful update adding new managed address with authority
    function test_updateManagementConfig_success_addNewManagedAddress() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = ProtocolManager.PeriodLimits({
            collRatioLimit: 200,
            marginSoftLimit: 100,
            marginHardLimit: 200,
            collateralCapLimit: 2_000_000e18,
            baseInterestRateLimit: 400,
            debtCapLimit: 2_000_000e18,
            vertexInterestRateLimit: 500,
            vertexStartLimit: 600,
            adjustmentVelocityLimit: 100,
            decayPerAdjustmentLimit: 50,
            vertexMultiplierMaxLimit: 20000,
            basePriceUSDLimit: 3e18,
            minPriceUSDLimit: 3e17,
            basePriceNativeLimit: 3e18,
            minPriceNativeLimit: 3e17
        });

        // Update management config
        protocolManager.updateManagementConfig(managedAddresses, limits, true);

        // Verify config was set correctly
        (bool hasAuthority, ProtocolManager.PeriodLimits memory storedLimits) =
            protocolManager.config(newManagedAddress);

        assertTrue(hasAuthority, "newManagedAddress should have authority");
        assertEq(storedLimits.collRatioLimit, 200, "collRatioLimit mismatch");
        assertEq(storedLimits.marginSoftLimit, 100, "marginSoftLimit mismatch");
        assertEq(storedLimits.marginHardLimit, 200, "marginHardLimit mismatch");
        assertEq(storedLimits.collateralCapLimit, 2_000_000e18, "collateralCapLimit mismatch");
        assertEq(storedLimits.baseInterestRateLimit, 400, "baseInterestRateLimit mismatch");
        assertEq(storedLimits.debtCapLimit, 2_000_000e18, "debtCapLimit mismatch");
        assertEq(storedLimits.vertexInterestRateLimit, 500, "vertexInterestRateLimit mismatch");
        assertEq(storedLimits.vertexStartLimit, 600, "vertexStartLimit mismatch");
        assertEq(storedLimits.adjustmentVelocityLimit, 100, "adjustmentVelocityLimit mismatch");
        assertEq(storedLimits.decayPerAdjustmentLimit, 50, "decayPerAdjustmentLimit mismatch");
        assertEq(storedLimits.vertexMultiplierMaxLimit, 20000, "vertexMultiplierMaxLimit mismatch");
        assertEq(storedLimits.basePriceUSDLimit, 3e18, "basePriceUSDLimit mismatch");
        assertEq(storedLimits.minPriceUSDLimit, 3e17, "minPriceUSDLimit mismatch");
        assertEq(storedLimits.basePriceNativeLimit, 3e18, "basePriceNativeLimit mismatch");
        assertEq(storedLimits.minPriceNativeLimit, 3e17, "minPriceNativeLimit mismatch");
    }

    /// @notice Test successful update of multiple managed addresses
    function test_updateManagementConfig_success_multipleAddresses() public {
        address secondAddress = makeAddr("secondAddress");

        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = newManagedAddress;
        managedAddresses[1] = secondAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = ProtocolManager.PeriodLimits({
            collRatioLimit: 300,
            marginSoftLimit: 150,
            marginHardLimit: 250,
            collateralCapLimit: 3_000_000e18,
            baseInterestRateLimit: 500,
            debtCapLimit: 3_000_000e18,
            vertexInterestRateLimit: 600,
            vertexStartLimit: 700,
            adjustmentVelocityLimit: 150,
            decayPerAdjustmentLimit: 75,
            vertexMultiplierMaxLimit: 25000,
            basePriceUSDLimit: 4e18,
            minPriceUSDLimit: 4e17,
            basePriceNativeLimit: 4e18,
            minPriceNativeLimit: 4e17
        });

        protocolManager.updateManagementConfig(managedAddresses, limits, true);

        // Verify first address
        (bool hasAuthority0,) = protocolManager.config(newManagedAddress);
        assertTrue(hasAuthority0, "newManagedAddress should have authority");

        // Verify second address
        (bool hasAuthority1, ProtocolManager.PeriodLimits memory storedLimits1) =
            protocolManager.config(secondAddress);
        assertTrue(hasAuthority1, "secondAddress should have authority");
        assertEq(storedLimits1.collRatioLimit, 300, "limits1.collRatioLimit mismatch");
    }

    /// @notice Test removing authority clears limits
    function test_updateManagementConfig_success_removeAuthority() public {
        // First add authority
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        protocolManager.updateManagementConfig(managedAddresses, limits, true);

        // Verify authority was added
        (bool hasAuthorityBefore,) = protocolManager.config(newManagedAddress);
        assertTrue(hasAuthorityBefore, "should have authority before removal");

        // Now remove authority
        protocolManager.updateManagementConfig(managedAddresses, limits, false);

        // Verify authority was removed and limits were cleared
        (bool hasAuthorityAfter, ProtocolManager.PeriodLimits memory storedLimits) =
            protocolManager.config(newManagedAddress);

        assertFalse(hasAuthorityAfter, "should not have authority after removal");
        assertEq(storedLimits.collRatioLimit, 0, "collRatioLimit should be cleared");
        assertEq(storedLimits.marginSoftLimit, 0, "marginSoftLimit should be cleared");
        assertEq(storedLimits.marginHardLimit, 0, "marginHardLimit should be cleared");
        assertEq(storedLimits.collateralCapLimit, 0, "collateralCapLimit should be cleared");
        assertEq(storedLimits.baseInterestRateLimit, 0, "baseInterestRateLimit should be cleared");
        assertEq(storedLimits.debtCapLimit, 0, "debtCapLimit should be cleared");
        assertEq(storedLimits.vertexInterestRateLimit, 0, "vertexInterestRateLimit should be cleared");
        assertEq(storedLimits.vertexStartLimit, 0, "vertexStartLimit should be cleared");
        assertEq(storedLimits.adjustmentVelocityLimit, 0, "adjustmentVelocityLimit should be cleared");
        assertEq(storedLimits.decayPerAdjustmentLimit, 0, "decayPerAdjustmentLimit should be cleared");
        assertEq(storedLimits.vertexMultiplierMaxLimit, 0, "vertexMultiplierMaxLimit should be cleared");
        assertEq(storedLimits.basePriceUSDLimit, 0, "basePriceUSDLimit should be cleared");
        assertEq(storedLimits.minPriceUSDLimit, 0, "minPriceUSDLimit should be cleared");
        assertEq(storedLimits.basePriceNativeLimit, 0, "basePriceNativeLimit should be cleared");
        assertEq(storedLimits.minPriceNativeLimit, 0, "minPriceNativeLimit should be cleared");
    }

    /// @notice Test updating existing managed address config
    function test_updateManagementConfig_success_updateExistingConfig() public {
        // borrowableCUSDC_MONAD was set during deployment, update its config
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory newLimits = new ProtocolManager.PeriodLimits[](1);
        newLimits[0] = ProtocolManager.PeriodLimits({
            collRatioLimit: 250,
            marginSoftLimit: 125,
            marginHardLimit: 225,
            collateralCapLimit: 2_500_000e18,
            baseInterestRateLimit: 450,
            debtCapLimit: 2_500_000e18,
            vertexInterestRateLimit: 550,
            vertexStartLimit: 650,
            adjustmentVelocityLimit: 125,
            decayPerAdjustmentLimit: 60,
            vertexMultiplierMaxLimit: 22000,
            basePriceUSDLimit: 5e18,
            minPriceUSDLimit: 5e17,
            basePriceNativeLimit: 5e18,
            minPriceNativeLimit: 5e17
        });

        protocolManager.updateManagementConfig(managedAddresses, newLimits, true);

        // Verify config was updated
        (bool hasAuthority, ProtocolManager.PeriodLimits memory storedLimits) =
            protocolManager.config(address(borrowableCUSDC_MONAD));

        assertTrue(hasAuthority, "should still have authority");
        assertEq(storedLimits.collRatioLimit, 250, "collRatioLimit should be updated");
        assertEq(storedLimits.baseInterestRateLimit, 450, "baseInterestRateLimit should be updated");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-elevated caller cannot call updateManagementConfig
    function test_updateManagementConfig_fail_unauthorizedCaller() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that updateManagementConfig reverts if called before final 1/3 of period
    function test_updateManagementConfig_fail_tooEarlyInPeriod() public {
        // Warp to the start of the current period (before the valid window)
        uint256 unixStartTimestamp = 1766966400;
        uint256 periodDuration = 604800;
        uint256 currentPeriod = (block.timestamp - unixStartTimestamp) / periodDuration;
        uint256 periodStart = unixStartTimestamp + (currentPeriod * periodDuration);
        vm.warp(periodStart + 1); // Just after period start, well before 2/3 mark

        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        vm.expectRevert(ProtocolManager.ProtocolManager__TooEarlyInPeriod.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that empty managedAddresses array reverts
    function test_updateManagementConfig_fail_emptyManagedAddresses() public {
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(
            new address[](0),
            new ProtocolManager.PeriodLimits[](0),
            true
        );
    }

    /// @notice Test that mismatched array lengths revert
    function test_updateManagementConfig_fail_arrayLengthMismatch() public {
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = newManagedAddress;
        managedAddresses[1] = makeAddr("secondAddress");

        // Only 1 limit for 2 addresses
        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that collRatioLimit exceeding max reverts
    function test_updateManagementConfig_fail_collRatioLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].collRatioLimit = 501; // Exceeds max of 500

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that baseInterestRateLimit exceeding max reverts
    function test_updateManagementConfig_fail_baseInterestRateLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].baseInterestRateLimit = 1001; // Exceeds max of 1000

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that vertexInterestRateLimit exceeding max reverts
    function test_updateManagementConfig_fail_vertexInterestRateLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexInterestRateLimit = 1001; // Exceeds max of 1000

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that vertexStartLimit exceeding max reverts
    function test_updateManagementConfig_fail_vertexStartLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexStartLimit = 1001; // Exceeds max of 1000

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that adjustmentVelocityLimit exceeding max reverts
    function test_updateManagementConfig_fail_adjustmentVelocityLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].adjustmentVelocityLimit = 501; // Exceeds max of 500

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that decayPerAdjustmentLimit exceeding max reverts
    function test_updateManagementConfig_fail_decayPerAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].decayPerAdjustmentLimit = 201; // Exceeds max of 200

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that vertexMultiplierMaxLimit exceeding max reverts
    function test_updateManagementConfig_fail_vertexMultiplierMaxLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexMultiplierMaxLimit = 50001; // Exceeds max of 50000

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that invalid params in second element of array still reverts
    function test_updateManagementConfig_fail_invalidParamsInSecondElement() public {
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = newManagedAddress;
        managedAddresses[1] = makeAddr("secondAddress");

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();
        limits[1].collRatioLimit = 501; // Invalid in second element

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that marginSoftLimit exceeding max reverts
    function test_updateManagementConfig_fail_marginSoftLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].marginSoftLimit = 301; // Exceeds max of 300

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that marginHardLimit exceeding max reverts
    function test_updateManagementConfig_fail_marginHardLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].marginHardLimit = 301; // Exceeds max of 300

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that collateralCapLimit exceeding max reverts
    function test_updateManagementConfig_fail_collateralCapLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].collateralCapLimit = uint120(type(uint112).max) + 1; // Exceeds max of type(uint112).max

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that debtCapLimit exceeding max reverts
    function test_updateManagementConfig_fail_debtCapLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].debtCapLimit = uint112(type(uint104).max) + 1; // Exceeds max of type(uint104).max

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    // Already enforced through type limits, impossible to test or exceed

    /// @notice Test that basePriceNativeLimit exceeding max reverts
    // function test_updateManagementConfig_fail_basePriceNativeLimitExceedsMax() public {
    //     address[] memory managedAddresses = new address[](1);
    //     managedAddresses[0] = newManagedAddress;

    //     ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
    //     limits[0] = _getValidLimits();
    //     limits[0].basePriceNativeLimit = type(uint88).max + 1; // Exceeds max of type(uint88).max

    //     vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
    //     protocolManager.updateManagementConfig(managedAddresses, limits, true);
    // }

    // /// @notice Test that minPriceNativeLimit exceeding max reverts
    // function test_updateManagementConfig_fail_minPriceNativeLimitExceedsMax() public {
    //     address[] memory managedAddresses = new address[](1);
    //     managedAddresses[0] = newManagedAddress;

    //     ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
    //     limits[0] = _getValidLimits();
    //     limits[0].minPriceNativeLimit = type(uint88).max + 1; // Exceeds max of type(uint88).max

    //     vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
    //     protocolManager.updateManagementConfig(managedAddresses, limits, true);
    // }

}
