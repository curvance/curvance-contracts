// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";

import { SECONDS_PER_YEAR, BPS, WAD } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import "forge-std/console2.sol";

// new DynamicIRM(
//             ICentralRegistry(address(centralRegistry)),
//             1000, // baseRatePerYear
//             1000, // vertexRatePerYear
//             5000, // vertexUtilizationStart
//             5000, // adjustmentVelocity
//             100, // decayRate
//             100000000 // 1000x maximum vertex multiplier
//         );
// TO-DO:
// Remove dependencies on assertGt/assertLe/assertLt/assertApproxEqRel
// Add better testing for precision loss errors with stateless fuzzing
// Clean up testing of Maximum/minimum vertex rates
// Clean up testing of Decay rate being applied
//
contract TestDynamicIRM is TestBaseMarketIsolated {
    DynamicIRM public IRM;

    address public owner;
    address public user;
    uint256 constant INITIAL_DEPOSIT = 200000e18;
    uint256 constant BORROW_AMOUNT_BELOW_VERTEX = 40_000e18; // 20% utilization
    uint256 constant BORROW_AMOUNT_ABOVE_VERTEX = 160_000e18; // 80% utilization
    uint256 constant BORROW_AMOUNT_JUST_UNDER_CAP = 199_000e18; // 99.5% utilization
    uint256 public constant INTEREST_ACCRUAL_PERIOD = 10 minutes;
    
    function setUp() public virtual override {
        super.setUp();

        owner = address(this);
        user = user1;

        // Deploy borrowable cDAI and simpleCUSDC.
        
        _deploySimpleCUSDC();
        IRM = IRMs[block.chainid][_DAI_ADDRESS];

        // Setup borrowable cDAI.
        
        _prepareDAI(owner, 100e18);
        dai.approve(address(borrowableCDAI), 100e18);

        // Setup simpleCUSDC.
        oracleManager.addCTokenSupport(address(simpleCUSDC));
        _prepareUSDC(owner, 100e6);
        usdc.approve(address(simpleCUSDC), 100e6);

        marketManagerIsolated.listTokens(address(simpleCUSDC),address(borrowableCDAI));

        _setCTokenConfigBasic(address(simpleCUSDC), 200_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 0, 200_000e18);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, INITIAL_DEPOSIT - 100e18);

        vm.startPrank(liquidityProvider);

        dai.approve(address(borrowableCDAI), INITIAL_DEPOSIT - 100e18);
        borrowableCDAI.deposit(INITIAL_DEPOSIT - 100e18, liquidityProvider);

        vm.stopPrank();
    }

    function test_DynamicIRM_PrecisionCheck() public {
        IRM.updateDynamicIRM(
            1500,
            1500,
            5500,
            1000,
            150,
            150000000,
            true
        );

        uint256 rate1 = IRM.borrowRate(0, 1e18);
        console2.log("borrowRate: %d", rate1);

        uint256 rate2 = IRM.borrowRate(0.1e18, 0.9e18);
        console2.log("borrowRate: %d", rate2);

        assertNotEq(rate1, rate2);
    }

    function testWhenUtilizationIsBelowVertexStartingPoint() public {
        vm.startPrank(user);

        // Set up collateral for borrowing
        _prepareUSDC(user, 100000e6);
        usdc.approve(address(simpleCUSDC), 100000e6);
        simpleCUSDC.depositAsCollateral(100000e6, user);

        // Initial state checks
        uint256 initialUtilization = IRM.utilizationRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );
        uint256 initialBorrowRate = IRM.borrowRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );

        // Borrow amount that keeps utilization below vertex point
        borrowableCDAI.borrow(BORROW_AMOUNT_BELOW_VERTEX, user);

        uint256 newUtilization = IRM.utilizationRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );
        uint256 newBorrowRate = IRM.borrowRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );
        (
            uint256 baseRatePerSecond,
            ,
            uint256 vertexStart,
            ,
            ,
            ,
            ,
            ,
        ) = IRM.ratesConfig();

        // Verify utilization is below vertex point
        assertLt(
            newUtilization,
            vertexStart,
            "Utilization should be below vertex point"
        );

        // Verify utilization increased
        assertGt(
            newUtilization,
            initialUtilization,
            "Utilization should increase after borrowing"
        );

        // Verify borrow rate increased
        assertGt(
            newBorrowRate,
            initialBorrowRate,
            "Borrow rate should increase with utilization"
        );

        // Verify we're using base interest rate calculation
        // (util * baseRatePerSecond) / WAD
        uint256 expectedRate = (newUtilization * baseRatePerSecond) / WAD;
        assertApproxEqRel(
            newBorrowRate,
            expectedRate,
            0.005e18, // 0.5% tolerance
            "Borrow rate should match base rate calculation"
        );

        vm.stopPrank();
    }

    function testWhenUtilizationIsAboveVertexStartingPoint() public {
        vm.startPrank(user);

        // Set up collateral for borrowing
        _prepareUSDC(user, 1000000e6);
        usdc.approve(address(simpleCUSDC), 1000000e6);
        simpleCUSDC.depositAsCollateral(1000000e6, user);

        skip(1);

        // Initial state checks
        uint256 initialUtilization = IRM.utilizationRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );
        uint256 initialBorrowRate = IRM.borrowRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );

        skip(1);

        // Borrow amount that pushes utilization above vertex point
        borrowableCDAI.borrow(BORROW_AMOUNT_ABOVE_VERTEX, user);

        uint256 newUtilization = IRM.utilizationRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );
        uint256 newBorrowRate = IRM.borrowRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );
        (
            uint256 baseRatePerSecond,
            uint256 vertexRatePerSecond,
            uint256 vertexStart,
            ,
            ,
            ,
            ,
            ,
        ) = IRM.ratesConfig();

        // Verify utilization is above vertex point
        assertGt(
            newUtilization,
            vertexStart,
            "Utilization should be above vertex point"
        );

        // Verify utilization increased
        assertGt(
            newUtilization,
            initialUtilization,
            "Utilization should increase after borrowing"
        );

        // Verify borrow rate increased
        assertGt(
            newBorrowRate,
            initialBorrowRate,
            "Borrow rate should increase with utilization"
        );

        // Verify we're using vertex interest rate calculation
        // baseRate(vertexStart) + vertexRate(util - vertexStart)
        uint256 vertexMultiplier = IRM.vertexMultiplier();
        uint256 baseComponent = (vertexStart * baseRatePerSecond) / WAD;
        uint256 vertexComponent = ((newUtilization - vertexStart) *
            vertexRatePerSecond *
            vertexMultiplier) / (WAD * WAD);
        uint256 expectedRate = baseComponent + vertexComponent;

        assertApproxEqRel(
            newBorrowRate,
            expectedRate,
            0.005e18, // 0.5% tolerance
            "Borrow rate should match vertex rate calculation"
        );

        vm.stopPrank();
    }

    function testVertexMultiplierIncreaseAboveThreshold() public {
        vm.startPrank(user);

        // Set up collateral for borrowing
        _prepareUSDC(user, 1000000e6);
        usdc.approve(address(simpleCUSDC), 1000000e6);
        simpleCUSDC.depositAsCollateral(1000000e6, user);

        // Initial state checks
        uint256 initialMultiplier = IRM.vertexMultiplier();
        (
            ,
            ,
            ,
            ,
            ,
            uint256 increaseThresholdStart,
            ,
            ,
        ) = IRM.ratesConfig();
        uint256 adjustmentRate = IRM.ADJUSTMENT_RATE();

        // Borrow enough to push utilization above increaseThresholdStart
        borrowableCDAI.borrow(BORROW_AMOUNT_ABOVE_VERTEX, user);

        // Move time forward to trigger multiplier update
        vm.warp(block.timestamp + adjustmentRate);

        // Force an interest rate update
        borrowableCDAI.accrueIfNeeded();

        uint256 newMultiplier = IRM.vertexMultiplier();
        uint256 utilization = IRM.utilizationRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );

        assertGt(
            utilization,
            increaseThresholdStart,
            "Utilization should be above increase threshold"
        );
        assertGt(
            newMultiplier,
            initialMultiplier,
            "Vertex multiplier should increase"
        );

        vm.stopPrank();
    }

    function testVertexMultiplierDecreaseBelowThreshold() public {
        // First increase the multiplier
        testVertexMultiplierIncreaseAboveThreshold();
        skip(20 minutes);

        vm.startPrank(user);
        uint256 highMultiplier = IRM.vertexMultiplier();

        // Repay most of the debt to drop utilization
        uint256 currentDebt = borrowableCDAI.debtBalance(address(user));
        uint256 repayAmount = (currentDebt * 90) / 100; // Repay 90%

        _prepareDAI(user, repayAmount);
        dai.approve(address(borrowableCDAI), repayAmount);
        borrowableCDAI.repay(repayAmount);
        (
            ,
            ,
            uint256 vertexStart,
            ,
            ,
            ,
            ,
            ,
        ) = IRM.ratesConfig();
        uint256 adjustmentRate = IRM.ADJUSTMENT_RATE();

        // Move time forward to trigger multiplier update
        skip(adjustmentRate);

        vm.stopPrank();
        vm.startPrank(user);

        // Force an interest rate update
        borrowableCDAI.accrueIfNeeded();

        uint256 newMultiplier = IRM.vertexMultiplier();
        uint256 utilization = IRM.utilizationRate(
            borrowableCDAI.assetsHeld(),
            borrowableCDAI.marketOutstandingDebt()
        );

        assertLt(
            utilization,
            vertexStart,
            "Utilization should be below vertexStart aka decrease threshold start"
        );
        assertLt(
            newMultiplier,
            highMultiplier,
            "Vertex multiplier should decrease"
        );

        vm.stopPrank();
    }

    function testVertexMultiplierUnderMaximumCap() public {
        vm.startPrank(user);

        // Set up collateral for borrowing
        _prepareUSDC(user, 2000000e6);
        usdc.approve(address(simpleCUSDC), 2000000e6);
        simpleCUSDC.depositAsCollateral(2000000e6, user);
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 vertexMultiplierMax,
        ) = IRM.ratesConfig();
        uint256 adjustmentRate = IRM.ADJUSTMENT_RATE();

        // Borrow to push utilization very high
        borrowableCDAI.borrow(BORROW_AMOUNT_ABOVE_VERTEX, user);

        // Move time forward multiple periods to allow multiplier to increase
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + adjustmentRate);
            borrowableCDAI.accrueIfNeeded();
        }

        uint256 finalMultiplier = IRM.vertexMultiplier();
        assertGt(
                finalMultiplier,
                WAD,
                "Multiplier should be above base WAD"
            );
        assertLe(
            finalMultiplier,
            vertexMultiplierMax,
            "Multiplier should not exceed maximum"
        );

        vm.stopPrank();
    }

    function testVertexMultiplierMaximumCapHit() public {
        vm.startPrank(user);

        // Set up collateral for borrowing
        _prepareUSDC(user, 3000000e6);
        usdc.approve(address(simpleCUSDC), 3000000e6);
        simpleCUSDC.depositAsCollateral(3000000e6, user);
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 vertexMultiplierMax,
        ) = IRM.ratesConfig();
        uint256 adjustmentRate = IRM.ADJUSTMENT_RATE();

        // Borrow to push utilization extremely high.
        borrowableCDAI.borrow(BORROW_AMOUNT_JUST_UNDER_CAP, user);

        // Move time forward multiple periods to allow multiplier to increase.
        for (uint256 i = 0; i < 200; i++) {
            vm.warp(block.timestamp + adjustmentRate);
            borrowableCDAI.accrueIfNeeded();
        }

        // Multiplier should be at cap now.
        assertEq(
            IRM.vertexMultiplier(),
            vertexMultiplierMax,
            "Multiplier should be equal to vertexMultiplierMax"
        );

        vm.warp(block.timestamp + adjustmentRate);
        borrowableCDAI.accrueIfNeeded();

        // Make sure multiplier is still at the cap even though it
        // theoretically could warrant being raised more.
        assertEq(
            IRM.vertexMultiplier(),
            vertexMultiplierMax,
            "Multiplier should be equal to vertexMultiplierMax still"
        );

        vm.stopPrank();
    }

    function testVertexMultiplierMinimumFloorHit() public {
        // First increase the multiplier.
        testVertexMultiplierIncreaseAboveThreshold();
        skip(20 minutes);

        vm.startPrank(user);
        // Repay almost all debt
        uint256 currentDebt = borrowableCDAI.debtBalance(address(user));
        _prepareDAI(user, currentDebt);
        dai.approve(address(borrowableCDAI), currentDebt);
        borrowableCDAI.repay(currentDebt);

        uint256 adjustmentRate = IRM.ADJUSTMENT_RATE();

        // Move time forward several adjustment periods
        uint256 adjustmentPeriods = 100;
        for (uint256 i = 0; i < adjustmentPeriods; i++) {
            vm.warp(block.timestamp + adjustmentRate);
            borrowableCDAI.accrueIfNeeded();
        }

        assertEq(
            IRM.vertexMultiplier(),
            WAD,
            "Multiplier should be at floor of 1 WAD"
        );

        vm.stopPrank();
    }

    function testOnlyDecayRateApplied() public {
        vm.startPrank(user);

        // Set up collateral for borrowing.
        _prepareUSDC(user, 2000000e6);
        usdc.approve(address(simpleCUSDC), 2000000e6);
        simpleCUSDC.depositAsCollateral(2000000e6, user);
        (
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 decayRate,
            ,
        ) = IRM.ratesConfig();
        uint256 adjustmentRate = IRM.ADJUSTMENT_RATE();

        // Borrow to push utilization very high.
        borrowableCDAI.borrow(BORROW_AMOUNT_ABOVE_VERTEX, user);

        // Move time forward multiple periods to allow multiplier to increase.
        uint256 adjustmentPeriods = 20;
        for (uint256 i = 0; i < adjustmentPeriods; i++) {
            vm.warp(block.timestamp + adjustmentRate);
            borrowableCDAI.accrueIfNeeded();
        }

        // This should push utilization to ~60% or so.
        _prepareDAI(user, BORROW_AMOUNT_BELOW_VERTEX);
        dai.approve(address(borrowableCDAI), BORROW_AMOUNT_BELOW_VERTEX);
        borrowableCDAI.repay(BORROW_AMOUNT_BELOW_VERTEX);
        uint256 currentMultiplier;

        // Loop through multiple periods making sure only decay applies.
        adjustmentPeriods = 10;
        for (uint256 i = 0; i < adjustmentPeriods; i++) {
            currentMultiplier = IRM.vertexMultiplier();
            uint256 decay = FixedPointMathLib.mulDiv(
                currentMultiplier,
                decayRate,
                BPS
            );

            vm.warp(block.timestamp + adjustmentRate);
            borrowableCDAI.accrueIfNeeded();

            // New vertexMultiplier should decrease by exactly decay if 
            assertEq(
                IRM.vertexMultiplier(),
                currentMultiplier - decay,
                "New vertexMultiplier should decrease by exactly decay."
            );
        }

        vm.stopPrank();
    }
}
