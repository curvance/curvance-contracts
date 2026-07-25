// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";

contract DynamicIRMCatchUpRegression is TestBaseMarketIsolated {
    struct BranchResult {
        uint256 marketDebt;
        uint256 totalAssets;
        uint256 borrowerDebt;
        uint256 vertexMultiplier;
        uint256 vestingEnd;
        uint256 timestamp;
    }

    DynamicIRM internal irm;
    address internal liquidityProvider;

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 77_777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77_777);

        usdc.approve(address(borrowableCUSDC), 77_777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77_777);

        marketManagerIsolated.listTokens(
            address(pendleStrategyCTokenSTETH), address(borrowableCUSDC)
        );
        _setCTokenConfigBasic(
            address(pendleStrategyCTokenSTETH), 100_000e18, 0
        );
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e6, 100_000e6);

        irm = IRMs[block.chainid][_USDC_ADDRESS];
        irm.updateDynamicIRM(
            250, // 2.5% annual base rate
            750, // 7.5% annual vertex rate
            9_000, // 90% utilization vertex
            500, // 5% adjustment velocity
            200, // 2% decay per adjustment
            100_000, // 10x maximum vertex multiplier
            true
        );

        liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 50_000e6);

        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 50_000e6);
        borrowableCUSDC.deposit(50_000e6, liquidityProvider);
        vm.stopPrank();

        mockUsdcFeed.setMockAnswer(1e9);

        deal(address(LP_wstETH_24Dec2025), user1, 10_000e18);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(
            address(pendleStrategyCTokenSTETH), 10_000e18
        );
        pendleStrategyCTokenSTETH.depositAsCollateral(10_000e18, user1);
        borrowableCUSDC.borrow(49_000e6, user1);
        vm.stopPrank();
    }

    function test_regression_missedPeriodsAdvanceDeadlineButAdjustIRMOnce()
        public
    {
        uint256 periods = 50;
        uint256 adjustmentRate = irm.ADJUSTMENT_RATE();
        uint256 initialMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        uint256 initialTotalAssets = borrowableCUSDC.totalAssets();
        uint256 initialMultiplier = irm.vertexMultiplier();

        assertGt(
            irm.utilizationRate(
                borrowableCUSDC.assetsHeld(), initialMarketDebt
            ),
            0.95e18,
            "fixture must increase the dynamic multiplier"
        );

        uint256 baseline = vm.snapshotState();
        BranchResult memory oneShot = _runOneShot(periods, adjustmentRate);

        assertTrue(
            vm.revertToState(baseline),
            "failed to restore the shared accrual baseline"
        );
        BranchResult memory cadence = _runCadence(periods, adjustmentRate);

        assertEq(
            oneShot.timestamp,
            cadence.timestamp,
            "branches must cover the same elapsed time"
        );
        assertEq(
            oneShot.vestingEnd,
            cadence.vestingEnd,
            "both branches must consume the same missed periods"
        );
        assertGt(
            oneShot.vestingEnd,
            oneShot.timestamp,
            "one-shot accrual must advance the deadline past the current time"
        );

        assertGt(
            oneShot.vertexMultiplier,
            initialMultiplier,
            "one-shot accrual should perform one upward adjustment"
        );
        assertGt(
            cadence.vertexMultiplier,
            oneShot.vertexMultiplier,
            "periodic accrual must apply more IRM adjustments"
        );
        assertGt(
            cadence.marketDebt,
            oneShot.marketDebt,
            "one-shot catch-up must under-accrue market debt"
        );
        assertGt(
            cadence.totalAssets,
            oneShot.totalAssets,
            "one-shot catch-up must under-accrue lender assets"
        );
        assertGt(
            cadence.borrowerDebt,
            oneShot.borrowerDebt,
            "one-shot catch-up must under-accrue borrower debt"
        );

        assertEq(
            oneShot.marketDebt - initialMarketDebt,
            oneShot.totalAssets - initialTotalAssets,
            "one-shot debt and asset growth must remain aligned"
        );
        assertEq(
            cadence.marketDebt - initialMarketDebt,
            cadence.totalAssets - initialTotalAssets,
            "periodic debt and asset growth must remain aligned"
        );
    }

    function _runOneShot(uint256 periods, uint256 adjustmentRate)
        internal
        returns (BranchResult memory result)
    {
        skip(periods * adjustmentRate);
        borrowableCUSDC.accrueIfNeeded();
        result = _capture();
    }

    function _runCadence(uint256 periods, uint256 adjustmentRate)
        internal
        returns (BranchResult memory result)
    {
        for (uint256 i; i < periods; ++i) {
            skip(adjustmentRate);
            borrowableCUSDC.accrueIfNeeded();
        }
        result = _capture();
    }

    function _capture() internal view returns (BranchResult memory result) {
        (, uint256 vestingEnd,,) = borrowableCUSDC.getYieldInformation();

        result = BranchResult({
            marketDebt: borrowableCUSDC.marketOutstandingDebt(),
            totalAssets: borrowableCUSDC.totalAssets(),
            borrowerDebt: borrowableCUSDC.debtBalance(user1),
            vertexMultiplier: irm.vertexMultiplier(),
            vestingEnd: vestingEnd,
            timestamp: block.timestamp
        });
    }
}
