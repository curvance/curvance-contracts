// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

contract TestProtocolManagerDeployment is TestProtocolManagerBase {

    function setUp() public override {
        super.setUp();
    }

    function test_ProtocolManagerDeployment_success() public {
        // Setup managed addresses
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);
        managedAddresses[1] = address(borrowableCWMON);

        // Setup period adjustment limits within valid bounds
        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](2);
        limits[0] = ProtocolManager.PeriodLimits({
            collRatioAdjustmentLimit: 100,           // <= 500 (MAXIMUM_COLL_RATIO_ADJUSTMENT_LIMIT)
            baseInterestRateAdjustmentLimit: 200,    // <= 1000 (MAXIMUM_INTEREST_RATE_ADJUSTMENT_LIMIT)
            vertexInterestRateAdjustmentLimit: 300,  // <= 1000
            vertexStartAdjustmentLimit: 400,         // <= 1000
            adjustmentRate: 50,                      // <= 500 (MAXIMUM_ADJUSTMENT_RATE_ADJUSTMENT_LIMIT)
            decayPerAdjustment: 10,                  // <= 200 (MAXIMUM_DECAY_RATE_ADJUSTMENT_LIMIT)
            vertexMultiplierMax: 10000,              // <= 50000 (MAXIMUM_VERTEX_MULTIPLIER_MAX_ADJUSTMENT_LIMIT)
            basePriceAdjustmentLimit: 1e18,          // <= type(uint88).max
            minPriceAdjustmentLimit: 1e17            // <= type(uint88).max
        });
        limits[1] = ProtocolManager.PeriodLimits({
            collRatioAdjustmentLimit: 150,
            baseInterestRateAdjustmentLimit: 250,
            vertexInterestRateAdjustmentLimit: 350,
            vertexStartAdjustmentLimit: 450,
            adjustmentRate: 75,
            decayPerAdjustment: 15,
            vertexMultiplierMax: 15000,
            basePriceAdjustmentLimit: 2e18,
            minPriceAdjustmentLimit: 2e17
        });

        // Setup permissions config - all permissions enabled
        ProtocolManager.PermsConfig memory permsConfig = ProtocolManager.PermsConfig({
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
            canModifyPositionManagers: true
        });

        // Deploy ProtocolManager
        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );

        // Assert immutable state variables are correctly set
        assertEq(address(protocolManager.centralRegistry()), address(centralRegistry), "centralRegistry mismatch");
        assertEq(protocolManager.protocolManager(), address(this), "protocolManager address mismatch");

        // Assert all permission flags are correctly set
        assertTrue(protocolManager.canModifyPriceGuards(), "canModifyPriceGuards should be true");
        assertTrue(protocolManager.canModifyTokenConfig(), "canModifyTokenConfig should be true");
        assertTrue(protocolManager.canModifyIRM(), "canModifyIRM should be true");
        assertTrue(protocolManager.canUnpause(), "canUnpause should be true");
        assertTrue(protocolManager.canModifyMintStatus(), "canModifyMintStatus should be true");
        assertTrue(protocolManager.canModifyCollateralizationStatus(), "canModifyCollateralizationStatus should be true");
        assertTrue(protocolManager.canModifyBorrowStatus(), "canModifyBorrowStatus should be true");
        assertTrue(protocolManager.canModifyLiquidationStatus(), "canModifyLiquidationStatus should be true");
        assertTrue(protocolManager.canModifyRedeemStatus(), "canModifyRedeemStatus should be true");
        assertTrue(protocolManager.canModifyTransferStatus(), "canModifyTransferStatus should be true");
        assertTrue(protocolManager.canModifyPositionManagers(), "canModifyPositionManagers should be true");

        // Assert config is correctly set for first managed address (borrowableCUSDC_MONAD)
        (bool hasAuthority0, ProtocolManager.PeriodLimits memory storedLimits0) = 
            protocolManager.config(address(borrowableCUSDC_MONAD));
        assertTrue(hasAuthority0, "borrowableCUSDC_MONAD should have authority");
        assertEq(storedLimits0.collRatioAdjustmentLimit, 100, "limits0.collRatioAdjustmentLimit mismatch");
        assertEq(storedLimits0.baseInterestRateAdjustmentLimit, 200, "limits0.baseInterestRateAdjustmentLimit mismatch");
        assertEq(storedLimits0.vertexInterestRateAdjustmentLimit, 300, "limits0.vertexInterestRateAdjustmentLimit mismatch");
        assertEq(storedLimits0.vertexStartAdjustmentLimit, 400, "limits0.vertexStartAdjustmentLimit mismatch");
        assertEq(storedLimits0.adjustmentRate, 50, "limits0.adjustmentRate mismatch");
        assertEq(storedLimits0.decayPerAdjustment, 10, "limits0.decayPerAdjustment mismatch");
        assertEq(storedLimits0.vertexMultiplierMax, 10000, "limits0.vertexMultiplierMax mismatch");
        assertEq(storedLimits0.basePriceAdjustmentLimit, 1e18, "limits0.basePriceAdjustmentLimit mismatch");
        assertEq(storedLimits0.minPriceAdjustmentLimit, 1e17, "limits0.minPriceAdjustmentLimit mismatch");

        // Assert config is correctly set for second managed address (borrowableCWMON)
        (bool hasAuthority1, ProtocolManager.PeriodLimits memory storedLimits1) = 
            protocolManager.config(address(borrowableCWMON));
        assertTrue(hasAuthority1, "borrowableCWMON should have authority");
        assertEq(storedLimits1.collRatioAdjustmentLimit, 150, "limits1.collRatioAdjustmentLimit mismatch");
        assertEq(storedLimits1.baseInterestRateAdjustmentLimit, 250, "limits1.baseInterestRateAdjustmentLimit mismatch");
        assertEq(storedLimits1.vertexInterestRateAdjustmentLimit, 350, "limits1.vertexInterestRateAdjustmentLimit mismatch");
        assertEq(storedLimits1.vertexStartAdjustmentLimit, 450, "limits1.vertexStartAdjustmentLimit mismatch");
        assertEq(storedLimits1.adjustmentRate, 75, "limits1.adjustmentRate mismatch");
        assertEq(storedLimits1.decayPerAdjustment, 15, "limits1.decayPerAdjustment mismatch");
        assertEq(storedLimits1.vertexMultiplierMax, 15000, "limits1.vertexMultiplierMax mismatch");
        assertEq(storedLimits1.basePriceAdjustmentLimit, 2e18, "limits1.basePriceAdjustmentLimit mismatch");
        assertEq(storedLimits1.minPriceAdjustmentLimit, 2e17, "limits1.minPriceAdjustmentLimit mismatch");

        // Assert constants are correct
        assertEq(protocolManager.MAXIMUM_COLL_RATIO_ADJUSTMENT_LIMIT(), 500, "MAXIMUM_COLL_RATIO_ADJUSTMENT_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_INTEREST_RATE_ADJUSTMENT_LIMIT(), 1000, "MAXIMUM_INTEREST_RATE_ADJUSTMENT_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_ADJUSTMENT_RATE_ADJUSTMENT_LIMIT(), 500, "MAXIMUM_ADJUSTMENT_RATE_ADJUSTMENT_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_DECAY_RATE_ADJUSTMENT_LIMIT(), 200, "MAXIMUM_DECAY_RATE_ADJUSTMENT_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_VERTEX_MULTIPLIER_MAX_ADJUSTMENT_LIMIT(), 50000, "MAXIMUM_VERTEX_MULTIPLIER_MAX_ADJUSTMENT_LIMIT mismatch");
        assertEq(protocolManager.periodDuration(), 604800, "periodDuration mismatch");
    }

    function test_ProtocolManagerDeployment_fail_invalidCentralRegistry() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry.selector);
        new ProtocolManager(
            ICentralRegistry(address(0x1234)), // Invalid CentralRegistry
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

    function test_ProtocolManagerDeployment_fail_emptyManagedAddresses() public {
        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            new address[](0),
            new ProtocolManager.PeriodLimits[](0)
        );
    }

    function test_ProtocolManagerDeployment_fail_arrayLengthMismatch() public {
        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);
        managedAddresses[1] = address(borrowableCWMON);

        // Only 1 limit for 2 addresses
        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

    function test_ProtocolManagerDeployment_fail_collRatioAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].collRatioAdjustmentLimit = 501; // Exceeds max of 500

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

    function test_ProtocolManagerDeployment_fail_baseInterestRateAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].baseInterestRateAdjustmentLimit = 1001; // Exceeds max of 1000

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

    function test_ProtocolManagerDeployment_fail_vertexInterestRateAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexInterestRateAdjustmentLimit = 1001; // Exceeds max of 1000

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

    function test_ProtocolManagerDeployment_fail_vertexStartAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexStartAdjustmentLimit = 1001; // Exceeds max of 1000

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

    function test_ProtocolManagerDeployment_fail_adjustmentRateExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].adjustmentRate = 501; // Exceeds max of 500

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

    function test_ProtocolManagerDeployment_fail_decayPerAdjustmentExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].decayPerAdjustment = 201; // Exceeds max of 200

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

    function test_ProtocolManagerDeployment_fail_vertexMultiplierMaxExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexMultiplierMax = 50001; // Exceeds max of 50000

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            permsConfig,
            managedAddresses,
            limits
        );
    }

}