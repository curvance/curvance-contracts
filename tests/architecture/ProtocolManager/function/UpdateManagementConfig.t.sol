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

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
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
    }
    
    /// SUCCESS TESTS ///

    /// @notice Test successful update adding new managed address with authority
    function test_updateManagementConfig_success_addNewManagedAddress() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = ProtocolManager.PeriodAdjustmentLimits({
            collRatioAdjustmentLimit: 200,
            baseInterestRateAdjustmentLimit: 400,
            vertexInterestRateAdjustmentLimit: 500,
            vertexStartAdjustmentLimit: 600,
            adjustmentRate: 100,
            decayPerAdjustment: 50,
            vertexMultiplierMax: 20000,
            basePriceAdjustmentLimit: 3e18,
            minPriceAdjustmentLimit: 3e17
        });

        // Update management config
        protocolManager.updateManagementConfig(managedAddresses, limits, true);

        // Verify config was set correctly
        (bool hasAuthority, ProtocolManager.PeriodAdjustmentLimits memory storedLimits) = 
            protocolManager.config(newManagedAddress);
        
        assertTrue(hasAuthority, "newManagedAddress should have authority");
        assertEq(storedLimits.collRatioAdjustmentLimit, 200, "collRatioAdjustmentLimit mismatch");
        assertEq(storedLimits.baseInterestRateAdjustmentLimit, 400, "baseInterestRateAdjustmentLimit mismatch");
        assertEq(storedLimits.vertexInterestRateAdjustmentLimit, 500, "vertexInterestRateAdjustmentLimit mismatch");
        assertEq(storedLimits.vertexStartAdjustmentLimit, 600, "vertexStartAdjustmentLimit mismatch");
        assertEq(storedLimits.adjustmentRate, 100, "adjustmentRate mismatch");
        assertEq(storedLimits.decayPerAdjustment, 50, "decayPerAdjustment mismatch");
        assertEq(storedLimits.vertexMultiplierMax, 20000, "vertexMultiplierMax mismatch");
        assertEq(storedLimits.basePriceAdjustmentLimit, 3e18, "basePriceAdjustmentLimit mismatch");
        assertEq(storedLimits.minPriceAdjustmentLimit, 3e17, "minPriceAdjustmentLimit mismatch");
    }

    /// @notice Test successful update of multiple managed addresses
    function test_updateManagementConfig_success_multipleAddresses() public {
        address secondAddress = makeAddr("secondAddress");

        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = newManagedAddress;
        managedAddresses[1] = secondAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = ProtocolManager.PeriodAdjustmentLimits({
            collRatioAdjustmentLimit: 300,
            baseInterestRateAdjustmentLimit: 500,
            vertexInterestRateAdjustmentLimit: 600,
            vertexStartAdjustmentLimit: 700,
            adjustmentRate: 150,
            decayPerAdjustment: 75,
            vertexMultiplierMax: 25000,
            basePriceAdjustmentLimit: 4e18,
            minPriceAdjustmentLimit: 4e17
        });

        protocolManager.updateManagementConfig(managedAddresses, limits, true);

        // Verify first address
        (bool hasAuthority0,) = protocolManager.config(newManagedAddress);
        assertTrue(hasAuthority0, "newManagedAddress should have authority");

        // Verify second address
        (bool hasAuthority1, ProtocolManager.PeriodAdjustmentLimits memory storedLimits1) = 
            protocolManager.config(secondAddress);
        assertTrue(hasAuthority1, "secondAddress should have authority");
        assertEq(storedLimits1.collRatioAdjustmentLimit, 300, "limits1.collRatioAdjustmentLimit mismatch");
    }

    /// @notice Test removing authority clears limits
    function test_updateManagementConfig_success_removeAuthority() public {
        // First add authority
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();

        protocolManager.updateManagementConfig(managedAddresses, limits, true);

        // Verify authority was added
        (bool hasAuthorityBefore,) = protocolManager.config(newManagedAddress);
        assertTrue(hasAuthorityBefore, "should have authority before removal");

        // Now remove authority
        protocolManager.updateManagementConfig(managedAddresses, limits, false);

        // Verify authority was removed and limits were cleared
        (bool hasAuthorityAfter, ProtocolManager.PeriodAdjustmentLimits memory storedLimits) = 
            protocolManager.config(newManagedAddress);
        
        assertFalse(hasAuthorityAfter, "should not have authority after removal");
        assertEq(storedLimits.collRatioAdjustmentLimit, 0, "limits should be cleared");
        assertEq(storedLimits.baseInterestRateAdjustmentLimit, 0, "limits should be cleared");
        assertEq(storedLimits.vertexInterestRateAdjustmentLimit, 0, "limits should be cleared");
        assertEq(storedLimits.vertexStartAdjustmentLimit, 0, "limits should be cleared");
        assertEq(storedLimits.adjustmentRate, 0, "limits should be cleared");
        assertEq(storedLimits.decayPerAdjustment, 0, "limits should be cleared");
        assertEq(storedLimits.vertexMultiplierMax, 0, "limits should be cleared");
        assertEq(storedLimits.basePriceAdjustmentLimit, 0, "limits should be cleared");
        assertEq(storedLimits.minPriceAdjustmentLimit, 0, "limits should be cleared");
    }

    /// @notice Test updating existing managed address config
    function test_updateManagementConfig_success_updateExistingConfig() public {
        // borrowableCUSDC_MONAD was set during deployment, update its config
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodAdjustmentLimits[] memory newLimits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        newLimits[0] = ProtocolManager.PeriodAdjustmentLimits({
            collRatioAdjustmentLimit: 250,
            baseInterestRateAdjustmentLimit: 450,
            vertexInterestRateAdjustmentLimit: 550,
            vertexStartAdjustmentLimit: 650,
            adjustmentRate: 125,
            decayPerAdjustment: 60,
            vertexMultiplierMax: 22000,
            basePriceAdjustmentLimit: 5e18,
            minPriceAdjustmentLimit: 5e17
        });

        protocolManager.updateManagementConfig(managedAddresses, newLimits, true);

        // Verify config was updated
        (bool hasAuthority, ProtocolManager.PeriodAdjustmentLimits memory storedLimits) = 
            protocolManager.config(address(borrowableCUSDC_MONAD));
        
        assertTrue(hasAuthority, "should still have authority");
        assertEq(storedLimits.collRatioAdjustmentLimit, 250, "collRatioAdjustmentLimit should be updated");
        assertEq(storedLimits.baseInterestRateAdjustmentLimit, 450, "baseInterestRateAdjustmentLimit should be updated");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-elevated caller cannot call updateManagementConfig
    function test_updateManagementConfig_fail_unauthorizedCaller() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();

        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that empty managedAddresses array reverts
    function test_updateManagementConfig_fail_emptyManagedAddresses() public {
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(
            new address[](0),
            new ProtocolManager.PeriodAdjustmentLimits[](0),
            true
        );
    }

    /// @notice Test that mismatched array lengths revert
    function test_updateManagementConfig_fail_arrayLengthMismatch() public {
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = newManagedAddress;
        managedAddresses[1] = makeAddr("secondAddress");

        // Only 1 limit for 2 addresses
        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that collRatioAdjustmentLimit exceeding max reverts
    function test_updateManagementConfig_fail_collRatioAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].collRatioAdjustmentLimit = 501; // Exceeds max of 500

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that baseInterestRateAdjustmentLimit exceeding max reverts
    function test_updateManagementConfig_fail_baseInterestRateAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].baseInterestRateAdjustmentLimit = 1001; // Exceeds max of 1000

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that vertexInterestRateAdjustmentLimit exceeding max reverts
    function test_updateManagementConfig_fail_vertexInterestRateAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexInterestRateAdjustmentLimit = 1001; // Exceeds max of 1000

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that vertexStartAdjustmentLimit exceeding max reverts
    function test_updateManagementConfig_fail_vertexStartAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexStartAdjustmentLimit = 1001; // Exceeds max of 1000

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that adjustmentRate exceeding max reverts
    function test_updateManagementConfig_fail_adjustmentRateExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].adjustmentRate = 501; // Exceeds max of 500

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that decayPerAdjustment exceeding max reverts
    function test_updateManagementConfig_fail_decayPerAdjustmentExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].decayPerAdjustment = 201; // Exceeds max of 200

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that vertexMultiplierMax exceeding max reverts
    function test_updateManagementConfig_fail_vertexMultiplierMaxExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = newManagedAddress;

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexMultiplierMax = 50001; // Exceeds max of 50000

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

    /// @notice Test that invalid params in second element of array still reverts
    function test_updateManagementConfig_fail_invalidParamsInSecondElement() public {
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = newManagedAddress;
        managedAddresses[1] = makeAddr("secondAddress");

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();
        limits[1].collRatioAdjustmentLimit = 501; // Invalid in second element

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateManagementConfig(managedAddresses, limits, true);
    }

}
