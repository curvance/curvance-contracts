// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { DynamicIRM } from "contracts/market/DynamicIRM.sol";

import { TestBaseDynamicIRM } from "../TestBaseDynamicIRM.sol";

import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";

contract UpdateDynamicIRMTest is TestBaseDynamicIRM {

    DynamicIRM public BorrowableCTokenIRM;

    function setUp() public override {
        super.setUp();
        BorrowableCTokenIRM = DynamicIRM(address(borrowableCUSDC.IRM()));

        deal(address(_USDC_ADDRESS), address(this), 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 50_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 50_000e6);

        // provide liquidity for borrowing
        address liquidityProvider = makeAddr("liquidityProvider");
        vm.startPrank(liquidityProvider);
        _prepareUSDC(liquidityProvider, 30_000e6);
        usdc.approve(address(borrowableCUSDC), 30_000e6);
        borrowableCUSDC.deposit(30_000e6, liquidityProvider);
        vm.stopPrank();

        // Set up user for borrowing
        deal(address(LP_wstETH_24Dec2025), user1, 10 ether);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10 ether);
        pendleStrategyCTokenSTETH.depositAsCollateral(10 ether, user1);

        borrowableCUSDC.borrow(20_000e6, user1);
        vm.stopPrank();

        skip(4 weeks);
        _refreshMockFeeds();
    }

    function test_updateDynamicIRM_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(DynamicIRM.DynamicIRM__Unauthorized.selector);
        BorrowableCTokenIRM.updateDynamicIRM(
            1500,
            1500,
            5500,
            1000,
            150,
            100000,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenAdjustmentVelocityExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentVelocity = 2000;

        vm.expectRevert(
            DynamicIRM.DynamicIRM__InvalidAdjustmentVelocity.selector
        );
        BorrowableCTokenIRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            maxVertexAdjustmentVelocity + 1,
            100,
            100000,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenAdjustmentVelocityIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentVelocity = 100;

        vm.expectRevert(
            DynamicIRM.DynamicIRM__InvalidAdjustmentVelocity.selector
        );

        BorrowableCTokenIRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            minVertexAdjustmentVelocity - 1,
            100,
            100000,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenDecayRateExceedsMaximum()
        public
    {
        uint256 maxVertexDecayRate = 200;

        vm.expectRevert(DynamicIRM.DynamicIRM__InvalidDecayRate.selector);
        BorrowableCTokenIRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            1000,
            maxVertexDecayRate + 1,
            100000,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenMaxMultiplierExceedsMaximum()
        public
    {
        uint256 maxVertexMultiplierMax = 500000; // 50e4
        
        vm.expectRevert(DynamicIRM.DynamicIRM__InvalidMultiplierMax.selector);
        BorrowableCTokenIRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            1000,
            100,
            maxVertexMultiplierMax + 1,
            true
        );
    }

    function test_updateDynamicIRM_success() public {
        BorrowableCTokenIRM.updateDynamicIRM(
            1500,
            1500,
            5500,
            1000,
            150,
            100000,
            true
        );
    }

    function test_updateDynamicIRM_accruesLinkedTokenBeforeConfigMutation() public {
        uint256 staleDebt = borrowableCUSDC.marketOutstandingDebt();
        uint256 snapshotId = vm.snapshotState();

        borrowableCUSDC.accrueIfNeeded();
        uint256 expectedDebt = borrowableCUSDC.marketOutstandingDebt();
        uint256 expectedTotalAssets = borrowableCUSDC.totalAssets();

        assertGt(expectedDebt, staleDebt, "setup should have pending borrow interest");
        assertTrue(
            vm.revertToState(snapshotId),
            "failed to restore pre-update irm state"
        );

        (uint64 oldBaseRatePerSecond,,,,,,,,) =
            BorrowableCTokenIRM.ratesConfig();

        BorrowableCTokenIRM.updateDynamicIRM(
            1500,
            1500,
            5500,
            1000,
            150,
            100000,
            true
        );

        (uint64 newBaseRatePerSecond,,,,,,,,) =
            BorrowableCTokenIRM.ratesConfig();

        assertEq(
            borrowableCUSDC.marketOutstandingDebt(),
            expectedDebt,
            "linked cToken debt should accrue before irm config mutation"
        );
        assertEq(
            borrowableCUSDC.totalAssets(),
            expectedTotalAssets,
            "linked cToken assets should accrue before irm config mutation"
        );
        assertNotEq(
            newBaseRatePerSecond,
            oldBaseRatePerSecond,
            "irm config should still update after linked cToken accrual"
        );
    }

    function test_updateDynamicIRM_clampsVertexMultiplier_whenLoweringMax_withoutReset() public {
        // Increase utilization and push the multiplier above 1x
        uint256 adjustmentRate = BorrowableCTokenIRM.ADJUSTMENT_RATE();

        vm.startPrank(user1);
        // Borrow in increments until utilization is higher than 85%
        for (uint256 i = 0; i < 20; i++) {
            uint256 util = BorrowableCTokenIRM.utilizationRate(
                borrowableCUSDC.assetsHeld(),
                borrowableCUSDC.marketOutstandingDebt()
            );
            if (util >= 0.85e18) {
                break;
            }
            borrowableCUSDC.borrow(1_000e6, user1);
        }
        vm.stopPrank();

        // skip a few adjustment periods
        for (uint256 i = 0; i < 3; i++) {
            skip(adjustmentRate);
            borrowableCUSDC.accrueIfNeeded();
        }

        uint256 preUpdateMultiplier = BorrowableCTokenIRM.vertexMultiplier();
        // Check that the multiplier is actually above 1x
        assertGt(preUpdateMultiplier, 1e18, "vertexMultiplier should be > 1x before lowering max");

        // Lower the vertexMultiplierMax to 1x without resetting
        BorrowableCTokenIRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            1000,
            100,
            10000, // vertexMultiplierMax -> 1x
            false  // vertexReset
        );

        // Verify the current multiplier was clamped down to the new maximum (1e18)
        assertEq(
            BorrowableCTokenIRM.vertexMultiplier(),
            1e18,
            "vertexMultiplier should clamp to new vertexMultiplierMax"
        );
    }

    function test_DynamicIRM_thresholdResolution_rejectsInvalidMultiplierMax() public {
            vm.expectRevert(DynamicIRM.DynamicIRM__InvalidMultiplierMax.selector);
            IRM.updateDynamicIRM(
                1500,
                1500,
                9900,
                1000,
                150,
                150000000,
                true
            );
            vm.expectRevert(DynamicIRM.DynamicIRM__InvalidMultiplierMax.selector);
            IRM.updateDynamicIRM(
                1500,
                1500,
                9899,
                1000,
                150,
                150000000,
                true
            );
            vm.expectRevert(DynamicIRM.DynamicIRM__InvalidMultiplierMax.selector);
            IRM.updateDynamicIRM(
                1500,
                1500,
                9898,
                1000,
                150,
                150000000,
                true
            );
            vm.expectRevert(DynamicIRM.DynamicIRM__InvalidMultiplierMax.selector);
            IRM.updateDynamicIRM(
                1500,
                1500,
                9897,
                1000,
                150,
                150000000,
                true
            );
            vm.expectRevert(DynamicIRM.DynamicIRM__InvalidMultiplierMax.selector);
            IRM.updateDynamicIRM(
                1500,
                1500,
                9896,
                1000,
                150,
                150000000,
                true
            );
            vm.expectRevert(DynamicIRM.DynamicIRM__InvalidMultiplierMax.selector);
            IRM.updateDynamicIRM(
                1500,
                1500,
                9895,
                1000,
                150,
                150000000,
                true
            );
        }
}
