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

        // Grant ProtocolManager market permissions so it can call updateDynamicIRM
        centralRegistry.addMarketPermissions(address(protocolManager));
    }

    /// SUCCESS TESTS ///

    /// @notice Test successful update of DynamicIRM parameters
    /// @dev Initial IRM values: baseRate=1000, vertexRate=1000, vertexStart=5000,
    ///      adjustmentVelocity=1000, decayRate=100, multiplierMax=100000
    ///      Limits: baseRate=200, vertexRate=300, vertexStart=400,
    ///      adjustmentVelocity=50, decayRate=10, multiplierMax=10000
    function test_updateDynamicIRM_success() public {
        // New values must be within limits of current values
        // Current: baseRate=1000, limit=200 → valid range: 800-1200
        uint256 newBaseRate = 1100;      // +100 (within 200 limit)
        uint256 newVertexRate = 1200;    // +200 (within 300 limit)
        uint256 newVertexStart = 5300;   // +300 (within 400 limit)
        uint256 newAdjustmentVelocity = 1040; // +40 (within 50 limit)
        uint256 newDecayRate = 105;      // +5 (within 10 limit)
        uint256 newMultiplierMax = 105000; // +5000 (within 10000 limit)
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

        ProtocolManager.PeriodLimits[] memory limits = new ProtocolManager.PeriodLimits[](1);
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

    /// ADJUSTMENT LIMIT TESTS ///

    /// @notice Test that exceeding baseInterestRate limit reverts
    /// @dev Initial baseRate=1000, limit=200 → valid range: 800-1200
    function test_updateDynamicIRM_fail_baseInterestRateLimitExceeded() public {
        // Try to increase by 201 (limit is 200)
        uint256 newBaseRate = 1201;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            newBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test that exceeding vertexInterestRate limit reverts
    /// @dev Initial vertexRate=1000, limit=300 → valid range: 700-1300
    function test_updateDynamicIRM_fail_vertexInterestRateLimitExceeded() public {
        // Try to increase by 301 (limit is 300)
        uint256 newVertexRate = 1301;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            VALID_BASE_RATE,
            newVertexRate,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test that exceeding vertexStart limit reverts
    /// @dev Initial vertexStart=5000, limit=400.
    function test_updateDynamicIRM_fail_vertexStartLimitExceeded() public {
        // Try to increase by 401 (limit is 400)
        uint256 newVertexStart = 5401;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            newVertexStart,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test that exceeding adjustmentVelocity limit reverts
    /// @dev Initial adjustmentVelocity=1000, limit=50.
    function test_updateDynamicIRM_fail_adjustmentVelocityLimitExceeded() public {
        // Try to increase by 51 (limit is 50)
        uint256 newAdjustmentVelocity = 1051;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            newAdjustmentVelocity,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test that exceeding decayPerAdjustment limit reverts
    /// @dev Initial decayRate=100, limit=10.
    function test_updateDynamicIRM_fail_decayPerAdjustmentLimitExceeded() public {
        // Try to increase by 11 (limit is 10)
        uint256 newDecayRate = 111;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            newDecayRate,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test that exceeding vertexMultiplierMax limit reverts
    /// @dev Initial multiplierMax=100000, limit=10000.
    function test_updateDynamicIRM_fail_vertexMultiplierMaxLimitExceeded() public {
        // Try to increase by 10001 (limit is 10000)
        uint256 newMultiplierMax = 110001;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            VALID_BASE_RATE,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            newMultiplierMax,
            false
        );
    }

    /// @notice Test that negative adjustment exceeding limit reverts
    /// @dev Initial baseRate=1000, limit=200 → valid range: 800-1200
    function test_updateDynamicIRM_fail_negativeAdjustmentExceedsLimit() public {
        // Try to decrease by 201 (limit is 200)
        uint256 newBaseRate = 799;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            newBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test cumulative adjustments within period are tracked
    /// @dev Two adjustments of +100 each should accumulate to +200 (at limit)
    function test_updateDynamicIRM_cumulativeAdjustmentsWithinPeriod() public {
        // First adjustment: +100 baseRate (within 200 limit)
        uint256 firstBaseRate = 1100;

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            firstBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Second adjustment: +100 more (cumulative +200, at limit)
        uint256 secondBaseRate = 1200;

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            secondBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Third adjustment should fail (cumulative +201 exceeds limit)
        uint256 thirdBaseRate = 1201;

        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            thirdBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );
    }

    /// @notice Test cumulative adjustments with mixed positive and negative
    /// @dev +150 then -100 should result in +50 cumulative adjustment
    function test_updateDynamicIRM_mixedAdjustmentsWithinPeriod() public {
        // First adjustment: +150 baseRate
        uint256 firstBaseRate = 1150;

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            firstBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Query current adjustment - should be exactly +150
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,,,,,int64 adjAfterFirst,,,,, ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);
        assertEq(adjAfterFirst, 150, "First adj should be +150");

        // Second adjustment: -100 (from 1150 to 1050)
        // Cumulative from original: +50 (within limit)
        uint256 secondBaseRate = 1050;

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            secondBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Query adjustment after second call - should be exactly +50
        (,,,,,int64 adjAfterSecond,,,,, ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);
        assertEq(adjAfterSecond, 50, "Second adj should be +50");

        // Can now adjust +150 more (cumulative becomes +200, at limit)
        uint256 thirdBaseRate = 1200;

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            thirdBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Verify final adjustment is exactly +200
        (,,,,,int64 adjAfterThird,,,,, ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);
        assertEq(adjAfterThird, 200, "Third adj should be +200");
    }

    /// @notice Test that new period resets adjustment tracking
    /// @dev After advancing to a new period, adjustments should reset.
    ///      The adjustment is calculated from current IRM value, not original.
    ///      So period reset allows new adjustments relative to current state.
    function test_updateDynamicIRM_periodResetAllowsNewAdjustments() public {
        // First adjustment: +200 baseRate (at limit)
        uint256 firstBaseRate = 1200;

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            firstBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Verify we're at limit
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (,,,,,int64 adjBefore,,,,, ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);
        assertEq(adjBefore, 200, "Should be at limit");

        // Trying to go any higher should fail
        vm.prank(manager);
        vm.expectRevert(ProtocolManager.ProtocolManager__ParametersAreInvalid.selector);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            1201,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Advance time to next period (periodDuration = 604800 = 1 week)
        vm.warp(block.timestamp + 604800);

        // In new period, adjustment tracking resets.
        // Current IRM baseRate is 1200
        // We can now make a fresh +200 adjustment from current value
        uint256 newPeriodBaseRate = 1400;

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            newPeriodBaseRate,
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Verify the update succeeded by checking IRM config
        (uint64 baseRatePerSecond,,,,,,,, ) = dynamicIRM.ratesConfig();
        assertTrue(baseRatePerSecond > 0, "Base rate should be updated");

        // Verify new period has fresh adjustment
        uint256 newPeriodTimestamp = protocolManager.getPeriodTimestamp();
        assertTrue(newPeriodTimestamp > periodTimestamp, "Should be in new period");

        (,,,,,int64 newPeriodAdj,,,,, ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), newPeriodTimestamp);
        assertEq(newPeriodAdj, 200, "New period adjustment should be +200");

        // Old period adjustment should still be preserved
        (,,,,,int64 oldPeriodAdj,,,,, ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);
        assertEq(oldPeriodAdj, adjBefore, "Old period adjustment should be preserved");
    }

    /// @notice Test that period adjustments are correctly tracked via getMarketPeriodAdjustments
    function test_updateDynamicIRM_periodAdjustmentsQuery() public {
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();

        // Make adjustments within limits
        uint256 newBaseRate = 1100;       // +100
        uint256 newVertexRate = 1200;     // +200
        uint256 newVertexStart = 5300;    // +300
        uint256 newAdjVelocity = 1040;    // +40
        uint256 newDecayRate = 105;       // +5
        uint256 newMultiplierMax = 105000; // +5000

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            newBaseRate,
            newVertexRate,
            newVertexStart,
            newAdjVelocity,
            newDecayRate,
            newMultiplierMax,
            false
        );

        // Query period adjustments
        (
            ,,,, // collRatio, marginSoft, marginHard, collateralCap
            , // debtCap
            int64 baseInterestRateAdj,
            int64 vertexInterestRateAdj,
            int64 vertexStartAdj,
            int16 adjustmentVelocityAdj,
            int16 decayPerAdjustmentAdj,
            int24 vertexMultiplierMaxAdj
        ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);

        // All adjustments should be exact
        assertEq(baseInterestRateAdj, 100, "Base rate adjustment should be +100");
        assertEq(vertexInterestRateAdj, 200, "Vertex rate adjustment should be +200");
        assertEq(vertexStartAdj, 300, "Vertex start adjustment should be +300");
        assertEq(adjustmentVelocityAdj, 40, "Adjustment velocity adjustment should be +40");
        assertEq(decayPerAdjustmentAdj, 5, "Decay adjustment should be +5");
        assertEq(vertexMultiplierMaxAdj, 5000, "Multiplier max adjustment should be +5000");
    }

    /// @notice Test successful negative adjustments within limits
    /// @dev Adjusting to lower vertex start requires valid DynamicIRM parameters
    function test_updateDynamicIRM_negativeAdjustmentsWithinLimits() public {
        // Decrease parameters within limits (keeping vertexStart valid for DynamicIRM)
        uint256 newBaseRate = 900;        // -100 (within 200 limit)
        uint256 newVertexRate = 800;      // -200 (within 300 limit)
        uint256 newVertexStart = 5300;    // +300 (increase to keep valid)
        uint256 newAdjVelocity = 960;     // -40 (within 50 limit)
        uint256 newDecayRate = 95;        // -5 (within 10 limit)
        uint256 newMultiplierMax = 95000; // -5000 (within 10000 limit)

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            newBaseRate,
            newVertexRate,
            newVertexStart,
            newAdjVelocity,
            newDecayRate,
            newMultiplierMax,
            false
        );

        // Query to verify adjustments were tracked
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (
            ,,,,,
            int64 baseInterestRateAdj,
            int64 vertexInterestRateAdj,
            int64 vertexStartAdj,
            int16 adjustmentVelocityAdj,
            int16 decayPerAdjustmentAdj,
            int24 vertexMultiplierMaxAdj
        ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);

        // All adjustments should be exact
        assertEq(baseInterestRateAdj, -100, "Base rate adjustment should be -100");
        assertEq(vertexInterestRateAdj, -200, "Vertex rate adjustment should be -200");
        assertEq(vertexStartAdj, 300, "Vertex start adjustment should be +300");
        assertEq(adjustmentVelocityAdj, -40, "Adjustment velocity adjustment should be -40");
        assertEq(decayPerAdjustmentAdj, -5, "Decay adjustment should be -5");
        assertEq(vertexMultiplierMaxAdj, -5000, "Multiplier max adjustment should be -5000");
    }

    /// @notice Test adjustment at exact limit boundary succeeds
    function test_updateDynamicIRM_exactLimitBoundary() public {
        // Adjust each parameter exactly to its limit
        uint256 newBaseRate = 1200;        // +200 (exactly at limit)
        uint256 newVertexRate = 1300;      // +300 (exactly at limit)
        uint256 newVertexStart = 5400;     // +400 (exactly at limit)
        uint256 newAdjVelocity = 1050;     // +50 (exactly at limit)
        uint256 newDecayRate = 110;        // +10 (exactly at limit)
        uint256 newMultiplierMax = 110000; // +10000 (exactly at limit)

        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            newBaseRate,
            newVertexRate,
            newVertexStart,
            newAdjVelocity,
            newDecayRate,
            newMultiplierMax,
            false
        );

        // Verify update succeeded
        (
            uint64 baseRatePerSecond,
            uint64 vertexRatePerSecond,
            uint64 vertexStartResult,
            ,,,,,
        ) = dynamicIRM.ratesConfig();

        assertTrue(baseRatePerSecond > 0, "Base rate should be set");
        assertTrue(vertexRatePerSecond > 0, "Vertex rate should be set");
        assertTrue(vertexStartResult > 0, "Vertex start should be set");

        // Verify adjustments are exactly at limits
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (
            ,,,,,
            int64 baseInterestRateAdj,
            int64 vertexInterestRateAdj,
            int64 vertexStartAdj,
            int16 adjustmentVelocityAdj,
            int16 decayPerAdjustmentAdj,
            int24 vertexMultiplierMaxAdj
        ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);

        assertEq(baseInterestRateAdj, 200, "Base rate at limit");
        assertEq(vertexInterestRateAdj, 300, "Vertex rate at limit");
        assertEq(vertexStartAdj, 400, "Vertex start at limit");
        assertEq(adjustmentVelocityAdj, 50, "Adjustment velocity at limit");
        assertEq(decayPerAdjustmentAdj, 10, "Decay at limit");
        assertEq(vertexMultiplierMaxAdj, 10000, "Multiplier max at limit");
    }

    /// @notice Test multiple parameters can hit their limits independently
    function test_updateDynamicIRM_multipleParametersIndependentLimits() public {
        // First call: max out baseRate adjustment
        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            1200, // +200 at limit
            VALID_VERTEX_RATE,
            VALID_VERTEX_START,
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Second call: can still adjust other parameters even though baseRate is at limit
        vm.prank(manager);
        protocolManager.updateDynamicIRM(
            address(dynamicIRM),
            1200, // no change to baseRate
            1300, // +300 at limit
            5400, // +400 at limit
            VALID_ADJUSTMENT_VELOCITY,
            VALID_DECAY_RATE,
            VALID_MULTIPLIER_MAX,
            false
        );

        // Verify all adjustments are tracked correctly
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();
        (
            ,,,,,
            int64 baseInterestRateAdj,
            int64 vertexInterestRateAdj,
            int64 vertexStartAdj,
            ,,
        ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);

        assertEq(baseInterestRateAdj, 200, "Base rate at limit");
        assertEq(vertexInterestRateAdj, 300, "Vertex rate at limit");
        assertEq(vertexStartAdj, 400, "Vertex start at limit");
    }

    /// @notice Test that zero adjustment doesn't affect limit tracking
    function test_updateDynamicIRM_zeroAdjustmentNoEffect() public {
        uint256 periodTimestamp = protocolManager.getPeriodTimestamp();

        // Call with same values (zero adjustment)
        vm.prank(manager);
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

        // Query period adjustments
        (
            ,,,,,
            int64 baseInterestRateAdj,
            int64 vertexInterestRateAdj,
            int64 vertexStartAdj,
            int16 adjustmentVelocityAdj,
            int16 decayPerAdjustmentAdj,
            int24 vertexMultiplierMaxAdj
        ) = protocolManager.getMarketPeriodAdjustments(address(dynamicIRM), periodTimestamp);

        // All adjustments should be exactly zero
        assertEq(baseInterestRateAdj, 0, "Base rate adjustment should be 0");
        assertEq(vertexInterestRateAdj, 0, "Vertex rate adjustment should be 0");
        assertEq(vertexStartAdj, 0, "Vertex start adjustment should be 0");
        assertEq(adjustmentVelocityAdj, 0, "Adjustment velocity should be 0");
        assertEq(decayPerAdjustmentAdj, 0, "Decay adjustment should be 0");
        assertEq(vertexMultiplierMaxAdj, 0, "Multiplier max adjustment should be 0");
    }
}
