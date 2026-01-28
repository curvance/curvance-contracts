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
            collRatioLimit: 100,
            collReqSoftLimit: 50,
            collReqHardLimit: 100,
            collateralCapLimit: 1_000_000e18,
            baseInterestRateLimit: 200,
            debtCapLimit: 1_000_000e18,
            vertexInterestRateLimit: 300,
            vertexStartLimit: 400,
            adjustmentVelocityLimit: 50,
            decayPerAdjustmentLimit: 10,
            vertexMultiplierMaxLimit: 10000,
            basePriceUSDLimit: 1e18,
            minPriceUSDLimit: 1e17,
            basePriceNativeLimit: 1e18,
            minPriceNativeLimit: 1e17
        });
        limits[1] = ProtocolManager.PeriodLimits({
            collRatioLimit: 150,
            collReqSoftLimit: 75,
            collReqHardLimit: 150,
            collateralCapLimit: 2_000_000e18,
            baseInterestRateLimit: 250,
            debtCapLimit: 2_000_000e18,
            vertexInterestRateLimit: 350,
            vertexStartLimit: 450,
            adjustmentVelocityLimit: 75,
            decayPerAdjustmentLimit: 15,
            vertexMultiplierMaxLimit: 15000,
            basePriceUSDLimit: 2e18,
            minPriceUSDLimit: 2e17,
            basePriceNativeLimit: 2e18,
            minPriceNativeLimit: 2e17
        });

        // Setup permissions config - all permissions enabled
        ProtocolManager.PermsConfig memory permsConfig = ProtocolManager.PermsConfig({
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
        assertEq(storedLimits0.collRatioLimit, 100, "limits0.collRatioLimit mismatch");
        assertEq(storedLimits0.collReqSoftLimit, 50, "limits0.collReqSoftLimit mismatch");
        assertEq(storedLimits0.collReqHardLimit, 100, "limits0.collReqHardLimit mismatch");
        assertEq(storedLimits0.collateralCapLimit, 1_000_000e18, "limits0.collateralCapLimit mismatch");
        assertEq(storedLimits0.baseInterestRateLimit, 200, "limits0.baseInterestRateLimit mismatch");
        assertEq(storedLimits0.debtCapLimit, 1_000_000e18, "limits0.debtCapLimit mismatch");
        assertEq(storedLimits0.vertexInterestRateLimit, 300, "limits0.vertexInterestRateLimit mismatch");
        assertEq(storedLimits0.vertexStartLimit, 400, "limits0.vertexStartLimit mismatch");
        assertEq(storedLimits0.adjustmentVelocityLimit, 50, "limits0.adjustmentVelocityLimit mismatch");
        assertEq(storedLimits0.decayPerAdjustmentLimit, 10, "limits0.decayPerAdjustmentLimit mismatch");
        assertEq(storedLimits0.vertexMultiplierMaxLimit, 10000, "limits0.vertexMultiplierMaxLimit mismatch");
        assertEq(storedLimits0.basePriceUSDLimit, 1e18, "limits0.basePriceUSDLimit mismatch");
        assertEq(storedLimits0.minPriceUSDLimit, 1e17, "limits0.minPriceUSDLimit mismatch");
        assertEq(storedLimits0.basePriceNativeLimit, 1e18, "limits0.basePriceNativeLimit mismatch");
        assertEq(storedLimits0.minPriceNativeLimit, 1e17, "limits0.minPriceNativeLimit mismatch");

        // Assert config is correctly set for second managed address (borrowableCWMON)
        (bool hasAuthority1, ProtocolManager.PeriodLimits memory storedLimits1) =
            protocolManager.config(address(borrowableCWMON));
        assertTrue(hasAuthority1, "borrowableCWMON should have authority");
        assertEq(storedLimits1.collRatioLimit, 150, "limits1.collRatioLimit mismatch");
        assertEq(storedLimits1.collReqSoftLimit, 75, "limits1.collReqSoftLimit mismatch");
        assertEq(storedLimits1.collReqHardLimit, 150, "limits1.collReqHardLimit mismatch");
        assertEq(storedLimits1.collateralCapLimit, 2_000_000e18, "limits1.collateralCapLimit mismatch");
        assertEq(storedLimits1.baseInterestRateLimit, 250, "limits1.baseInterestRateLimit mismatch");
        assertEq(storedLimits1.debtCapLimit, 2_000_000e18, "limits1.debtCapLimit mismatch");
        assertEq(storedLimits1.vertexInterestRateLimit, 350, "limits1.vertexInterestRateLimit mismatch");
        assertEq(storedLimits1.vertexStartLimit, 450, "limits1.vertexStartLimit mismatch");
        assertEq(storedLimits1.adjustmentVelocityLimit, 75, "limits1.adjustmentVelocityLimit mismatch");
        assertEq(storedLimits1.decayPerAdjustmentLimit, 15, "limits1.decayPerAdjustmentLimit mismatch");
        assertEq(storedLimits1.vertexMultiplierMaxLimit, 15000, "limits1.vertexMultiplierMaxLimit mismatch");
        assertEq(storedLimits1.basePriceUSDLimit, 2e18, "limits1.basePriceUSDLimit mismatch");
        assertEq(storedLimits1.minPriceUSDLimit, 2e17, "limits1.minPriceUSDLimit mismatch");
        assertEq(storedLimits1.basePriceNativeLimit, 2e18, "limits1.basePriceNativeLimit mismatch");
        assertEq(storedLimits1.minPriceNativeLimit, 2e17, "limits1.minPriceNativeLimit mismatch");

        // Assert constants are correct
        assertEq(protocolManager.MAXIMUM_COLL_RATIO_LIMIT(), 500, "MAXIMUM_COLL_RATIO_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_COLL_REQ_LIMIT(), 500, "MAXIMUM_COLL_REQ_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_INTEREST_RATE_LIMIT(), 1000, "MAXIMUM_INTEREST_RATE_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_ADJUSTMENT_VELOCITY_LIMIT(), 300, "MAXIMUM_ADJUSTMENT_VELOCITY_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_DECAY_RATE_LIMIT(), 120, "MAXIMUM_DECAY_RATE_LIMIT mismatch");
        assertEq(protocolManager.MAXIMUM_VERTEX_MULTIPLIER_MAX_LIMIT(), 50000, "MAXIMUM_VERTEX_MULTIPLIER_MAX_LIMIT mismatch");
        assertEq(protocolManager.PERIOD_DURATION(), 604800, "periodDuration mismatch");
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

    function test_ProtocolManagerDeployment_fail_collRatioLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].collRatioLimit = 501; // Exceeds max of 500

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

    function test_ProtocolManagerDeployment_fail_baseInterestRateLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].baseInterestRateLimit = 1001; // Exceeds max of 1000

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

    function test_ProtocolManagerDeployment_fail_vertexInterestRateLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexInterestRateLimit = 1001; // Exceeds max of 1000

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

    function test_ProtocolManagerDeployment_fail_vertexStartLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexStartLimit = 1001; // Exceeds max of 1000

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

    function test_ProtocolManagerDeployment_fail_adjustmentVelocityLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].adjustmentVelocityLimit = 301; // Exceeds max of 300

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

    function test_ProtocolManagerDeployment_fail_decayPerAdjustmentLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].decayPerAdjustmentLimit = 121; // Exceeds max of 120

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

    function test_ProtocolManagerDeployment_fail_vertexMultiplierMaxLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].vertexMultiplierMaxLimit = 50001; // Exceeds max of 50000

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

    function test_ProtocolManagerDeployment_fail_collReqSoftLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].collReqSoftLimit = 501; // Exceeds max of 500

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

    function test_ProtocolManagerDeployment_fail_collReqHardLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].collReqHardLimit = 501; // Exceeds max of 500

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

    function test_ProtocolManagerDeployment_fail_collateralCapLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].collateralCapLimit = uint120(type(uint112).max) + 1; // Exceeds max of type(uint112).max

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

    function test_ProtocolManagerDeployment_fail_debtCapLimitExceedsMax() public {
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(borrowableCUSDC_MONAD);

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
        limits[0] = _getValidLimits();
        limits[0].debtCapLimit = uint112(type(uint104).max) + 1; // Exceeds max of type(uint104).max

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

    // Already enforced through type limits, impossible to test or exceed

    // function test_ProtocolManagerDeployment_fail_basePriceNativeLimitExceedsMax() public {
    //     address[] memory managedAddresses = new address[](1);
    //     managedAddresses[0] = address(borrowableCUSDC_MONAD);

    //     ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
    //     limits[0] = _getValidLimits();
    //     limits[0].basePriceNativeLimit = uint256(type(uint88).max) + 1; // Exceeds max of type(uint88).max

    //     ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

    //     vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
    //     new ProtocolManager(
    //         ICentralRegistry(address(centralRegistry)),
    //         address(this),
    //         permsConfig,
    //         managedAddresses,
    //         limits
    //     );
    // }

    // function test_ProtocolManagerDeployment_fail_minPriceNativeLimitExceedsMax() public {
    //     address[] memory managedAddresses = new address[](1);
    //     managedAddresses[0] = address(borrowableCUSDC_MONAD);

    //     ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
    //     limits[0] = _getValidLimits();
    //     limits[0].minPriceNativeLimit = uint256(type(uint88).max) + 1; // Exceeds max of type(uint88).max

    //     ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

    //     vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
    //     new ProtocolManager(
    //         ICentralRegistry(address(centralRegistry)),
    //         address(this),
    //         permsConfig,
    //         managedAddresses,
    //         limits
    //     );
    // }

}
