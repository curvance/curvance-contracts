// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Tests for ProtocolManager.updateDynamicIRM
/// @dev The manager (protocolManager address) calls updateDynamicIRM to update
///      the interest rate model configuration for a DynamicIRM contract.
contract TestProtocolManagerUpdateDynamicIRM is TestProtocolManagerBase {

    address public manager;
    DynamicIRM public dynamicIRM;

    // Valid IRM parameters (in BPS)
    uint256 constant VALID_BASE_RATE = 1000;        // 10% per year
    uint256 constant VALID_VERTEX_RATE = 1000;      // 10% per year
    uint256 constant VALID_VERTEX_START = 5000;     // 50% utilization
    uint256 constant VALID_ADJUSTMENT_VELOCITY = 1000; // 10%
    uint256 constant VALID_DECAY_RATE = 100;        // 1%
    uint256 constant VALID_MULTIPLIER_MAX = 100000; // 10x

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");

        // Get the DynamicIRM that was deployed for USDC in the base setup
        // The IRM is linked to borrowableCUSDC_MONAD
        dynamicIRM = DynamicIRM(IRMs[block.chainid][_USDC_ADDRESS]);

        // Deploy ProtocolManager with the DynamicIRM as a managed address
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(dynamicIRM);

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory permsConfig = _getDefaultPermsConfig();

        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            permsConfig,
            managedAddresses,
            limits
        );

        // Grant ProtocolManager market permissions so it can call updateDynamicIRM
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful update of DynamicIRM parameters
    function test_updateDynamicIRM_success() public {
        uint256 newBaseRate = 500;       // 5% per year
        uint256 newVertexRate = 2000;    // 20% per year
        uint256 newVertexStart = 7000;   // 70% utilization
        uint256 newAdjustmentVelocity = 500;
        uint256 newDecayRate = 50;
        uint256 newMultiplierMax = 50000;
        bool vertexReset = false;

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            newBaseRate,
            newVertexRate,
            newVertexStart,
            newAdjustmentVelocity,
            newDecayRate,
            newMultiplierMax,
            vertexReset
        );

        // Verify IRM parameters were updated via ratesConfig struct
        (
            uint64 baseRatePerSecond,
            uint64 vertexRatePerSecond,
            uint64 vertexStartResult,
            ,,,,,
        ) = dynamicIRM.ratesConfig();

        // Values are converted: BPS -> WAD (multiply by 1e14)
        // baseRatePerSecond = (baseRatePerYear_WAD * WAD) / (SECONDS_PER_YEAR * vertexStart_WAD)
        // vertexRatePerSecond = (vertexRatePerYear_WAD * WAD) / (SECONDS_PER_YEAR * (WAD - vertexStart_WAD))
        uint256 baseRateWad = newBaseRate * 1e14;
        uint256 vertexRateWad = newVertexRate * 1e14;
        uint256 vertexStartWad = newVertexStart * 1e14;
        uint256 WAD = 1e18;

        uint256 expectedBaseRate = (baseRateWad * WAD) / (365 days * vertexStartWad);
        uint256 expectedVertexRate = (vertexRateWad * WAD) / (365 days * (WAD - vertexStartWad));

        assertEq(baseRatePerSecond, expectedBaseRate, "Base rate not updated");
        assertEq(vertexRatePerSecond, expectedVertexRate, "Vertex rate not updated");
        assertEq(vertexStartResult, vertexStartWad, "Vertex start not updated");
    }

    /// @notice Test successful update with vertex reset
    function test_updateDynamicIRM_success_withVertexReset() public {
        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            true   // vertexReset
        );

        // Verify vertexMultiplier was reset to 1e18
        assertEq(dynamicIRM.vertexMultiplier(), 1e18, "Vertex multiplier not reset");
    }

    /// @notice Test that canModifyIRM is properly set from PermsConfig
    function test_canModifyIRM_properlySetFromPermsConfig() public view {
        // Default config has canModifyIRM = true
        assertTrue(protocolManager.canModifyIRM(), "canModifyIRM should be true");
    }

    /// FAILURE TESTS ///

    /// @notice Test that non-manager cannot call updateDynamicIRM
    function test_updateDynamicIRM_fail_notManager() public {
        address notManager = makeAddr("notManager");

        vm.prank(notManager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test that manager cannot manage IRM without authority
    function test_updateDynamicIRM_fail_irmNoAuthority() public {
        // Deploy a new IRM that doesn't have authority
        DynamicIRM unauthorizedIRM = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX
        );

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.updateDynamicIRM(
            address(unauthorizedIRM), // No authority for this IRM
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test that updateDynamicIRM fails when canModifyIRM is false
    function test_updateDynamicIRM_fail_canModifyIRMDisabled() public {
        // Deploy ProtocolManager with canModifyIRM = false
        address[] memory managedAddresses = new address[](1);
        managedAddresses[0] = address(dynamicIRM);

        ProtocolManager.PeriodAdjustmentLimits[] memory limits = new ProtocolManager.PeriodAdjustmentLimits[](1);
        limits[0] = _getValidLimits();

        ProtocolManager.PermsConfig memory restrictedPerms = ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canModifyTokenConfig: true,
            canModifyIRM: false, // Disabled
            canUnpause: true,
            canModifyMintStatus: true,
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

        // Verify canModifyIRM is false
        assertFalse(restrictedPM.canModifyIRM(), "canModifyIRM should be false");

        // Try to update IRM - should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        restrictedPM.updateDynamicIRM(
            address(dynamicIRM),
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }
}
