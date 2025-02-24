// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { MockSimplePToken } from "contracts/mocks/MockSimplePToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

// new DynamicInterestRateModel(
//             ICentralRegistry(address(centralRegistry)),
//             1000, // baseRatePerYear
//             1000, // vertexRatePerYear
//             5000, // vertexUtilizationStart
//             4 hours, // adjustmentRate
//             5000, // adjustmentVelocity
//             100000000, // 1000x maximum vertex multiplier
//             100 // decayRate
//         );
contract TestDynamicInterestRateWithEToken is TestBaseMarket {
    DynamicInterestRateModel public interestRateModel;
    address public owner;
    address public user;
    uint256 constant INITIAL_DEPOSIT = 200000e18;
    uint256 constant BORROW_AMOUNT_BELOW_VERTEX = 40000e18; // 20% utilization
    uint256 constant BORROW_AMOUNT_ABOVE_VERTEX = 160000e18; // 80% utilization
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 public constant INTEREST_COMPOUND_RATE = 10 minutes;
    MockSimplePToken public pUSDC;

    function setUp() public virtual override {
        super.setUp();

        owner = address(this);
        user = user1;

        // Deploy eDAI and pUSDC
        _deployEDAI();
        _deployPUSDC();
        interestRateModel = interestRateModels[block.chainid][_DAI_ADDRESS];

        // Setup eToken (eDAI)
        oracleManager.addMTokenSupport(address(eDAI));
        _prepareDAI(owner, 100e18);
        dai.approve(address(eDAI), 100e18);
        marketManager.listToken(address(eDAI));

        // Setup pToken (pUSDC)
        oracleManager.addMTokenSupport(address(pUSDC));
        _prepareUSDC(owner, 100e6);
        usdc.approve(address(pUSDC), 100e6);
        marketManager.listToken(address(pUSDC));
        marketManager.updatePositionToken(
            address(pUSDC),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(pUSDC);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, INITIAL_DEPOSIT - 100e18);
        vm.startPrank(liquidityProvider);
        dai.approve(address(eDAI), INITIAL_DEPOSIT - 100e18);
        eDAI.mint(INITIAL_DEPOSIT - 100e18);
        vm.stopPrank();
    }

    function _deployPUSDC() internal returns (MockSimplePToken) {
        pUSDC = new MockSimplePToken(
            ICentralRegistry(address(centralRegistry)),
            address(usdc),
            address(marketManager)
        );
        return pUSDC;
    }

    function testWhenUtilizationIsBelowVertexStartingPoint() public {
        vm.startPrank(user);
        // given
        // Set up collateral for borrowing
        _prepareUSDC(user, 100000e6);
        usdc.approve(address(pUSDC), 100000e6);
        pUSDC.depositAsCollateral(100000e6, user);

        // Initial state checks
        uint256 initialUtilization = interestRateModel.utilizationRate(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );
        uint256 initialBorrowRate = interestRateModel.getBorrowRatePerYear(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );

        // when
        // Borrow amount that keeps utilization below vertex point
        eDAI.borrow(BORROW_AMOUNT_BELOW_VERTEX);

        // then
        uint256 newUtilization = interestRateModel.utilizationRate(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );
        uint256 newBorrowRate = interestRateModel.getBorrowRatePerYear(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );
        (, , uint256 vertexPoint, , , , , , , , ) = interestRateModel
            .ratesConfig();

        // Verify utilization is below vertex point
        assertLt(
            newUtilization,
            vertexPoint,
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
        // (util * baseInterestRate) / WAD
        (uint256 baseInterestRate, , , , , , , , , , ) = interestRateModel
            .ratesConfig();
        uint256 expectedRate = (SECONDS_PER_YEAR *
            (newUtilization * baseInterestRate)) /
            WAD /
            INTEREST_COMPOUND_RATE;
        assertApproxEqRel(
            newBorrowRate,
            expectedRate,
            0.01e18, // 1% tolerance
            "Borrow rate should match base rate calculation"
        );

        vm.stopPrank();
    }

    function testWhenUtilizationIsAboveVertexStartingPoint() public {
        vm.startPrank(user);
        // given
        // Set up collateral for borrowing
        _prepareUSDC(user, 1000000e6);
        usdc.approve(address(pUSDC), 1000000e6);
        pUSDC.depositAsCollateral(1000000e6, user);

        // Initial state checks
        uint256 initialUtilization = interestRateModel.utilizationRate(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );
        uint256 initialBorrowRate = interestRateModel.getBorrowRatePerYear(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );

        // when
        // Borrow amount that pushes utilization above vertex point
        eDAI.borrow(BORROW_AMOUNT_ABOVE_VERTEX);

        // then
        uint256 newUtilization = interestRateModel.utilizationRate(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );
        uint256 newBorrowRate = interestRateModel.getBorrowRatePerYear(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );
        (, , uint256 vertexPoint, , , , , , , , ) = interestRateModel
            .ratesConfig();

        // Verify utilization is above vertex point
        assertGt(
            newUtilization,
            vertexPoint,
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
        // baseRate(vertexPoint) + vertexRate(util - vertexPoint)
        (
            uint256 baseInterestRate,
            uint256 vertexInterestRate,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = interestRateModel.ratesConfig();
        uint256 vertexMultiplier = interestRateModel.vertexMultiplier();
        uint256 baseComponent = (vertexPoint * baseInterestRate) / WAD;
        uint256 vertexComponent = ((newUtilization - vertexPoint) *
            vertexInterestRate *
            vertexMultiplier) / (WAD * WAD);
        uint256 expectedRate = (SECONDS_PER_YEAR *
            (baseComponent + vertexComponent)) / INTEREST_COMPOUND_RATE;

        assertApproxEqRel(
            newBorrowRate,
            expectedRate,
            0.01e18, // 1% tolerance
            "Borrow rate should match vertex rate calculation"
        );

        vm.stopPrank();
    }

    function testVertexMultiplierIncreaseAboveThreshold() public {
        vm.startPrank(user);
        // given
        // Set up collateral for borrowing
        _prepareUSDC(user, 1000000e6);
        usdc.approve(address(pUSDC), 1000000e6);
        pUSDC.depositAsCollateral(1000000e6, user);

        // Initial state checks
        uint256 initialMultiplier = interestRateModel.vertexMultiplier();
        (
            ,
            ,
            ,
            uint256 adjustmentRate,
            ,
            ,
            uint256 increaseThreshold,
            ,
            ,
            ,

        ) = interestRateModel.ratesConfig();

        // when
        // Borrow enough to push utilization above increaseThreshold
        eDAI.borrow(BORROW_AMOUNT_ABOVE_VERTEX);

        // Move time forward to trigger multiplier update
        vm.warp(block.timestamp + adjustmentRate);

        // Force an interest rate update
        eDAI.accrueInterest();

        // then
        uint256 newMultiplier = interestRateModel.vertexMultiplier();
        uint256 utilization = interestRateModel.utilizationRate(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );

        assertGt(
            utilization,
            increaseThreshold,
            "Utilization should be above increase threshold"
        );
        assertGt(
            newMultiplier,
            initialMultiplier,
            "Vertex multiplier should increase"
        );
    }

    function testVertexMultiplierDecreaseBelowThreshold() public {
        // First increase the multiplier
        testVertexMultiplierIncreaseAboveThreshold();

        vm.startPrank(user);
        uint256 highMultiplier = interestRateModel.vertexMultiplier();

        // Repay most of the debt to drop utilization
        uint256 currentDebt = eDAI.debtBalanceCached(address(user));
        uint256 repayAmount = (currentDebt * 90) / 100; // Repay 90%

        _prepareDAI(user, repayAmount);
        dai.approve(address(eDAI), repayAmount);
        eDAI.repay(repayAmount);

        (
            ,
            ,
            ,
            uint256 adjustmentRate,
            ,
            ,
            ,
            ,
            ,
            uint256 decreaseThreshold,

        ) = interestRateModel.ratesConfig();

        // Move time forward to trigger multiplier update
        vm.warp(block.timestamp + adjustmentRate);

        // Force an interest rate update
        eDAI.accrueInterest();

        uint256 newMultiplier = interestRateModel.vertexMultiplier();
        uint256 utilization = interestRateModel.utilizationRate(
            eDAI.marketUnderlyingHeld(),
            eDAI.totalBorrows(),
            eDAI.convertToAssets(eDAI.totalReserves())
        );

        assertLt(
            utilization,
            decreaseThreshold,
            "Utilization should be below decrease threshold"
        );
        assertLt(
            newMultiplier,
            highMultiplier,
            "Vertex multiplier should decrease"
        );

        vm.stopPrank();
    }

    function testVertexMultiplierMaximumCap() public {
        vm.startPrank(user);
        // given
        // Set up collateral for borrowing
        _prepareUSDC(user, 2000000e6);
        usdc.approve(address(pUSDC), 2000000e6);
        pUSDC.depositAsCollateral(2000000e6, user);

        (
            ,
            ,
            ,
            uint256 adjustmentRate,
            ,
            uint256 vertexMultiplierMax,
            ,
            ,
            ,
            ,

        ) = interestRateModel.ratesConfig();

        // Borrow to push utilization very high
        eDAI.borrow(BORROW_AMOUNT_ABOVE_VERTEX);

        // Move time forward multiple periods to allow multiplier to increase
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + adjustmentRate);
            eDAI.accrueInterest();
        }

        uint256 finalMultiplier = interestRateModel.vertexMultiplier();
        assertLe(
            finalMultiplier,
            vertexMultiplierMax,
            "Multiplier should not exceed maximum"
        );
        vm.stopPrank();
    }

    function testVertexMultiplierMinimumFloor() public {
        // First increase the multiplier
        testVertexMultiplierIncreaseAboveThreshold();

        vm.startPrank(user);
        // Repay almost all debt
        uint256 currentDebt = eDAI.debtBalanceCached(address(user));
        _prepareDAI(user, currentDebt);
        dai.approve(address(eDAI), currentDebt);
        eDAI.repay(currentDebt);

        // Move time forward several adjustment periods
        uint256 adjustmentPeriods = 10;
        (, , , uint256 adjustmentRate, , , , , , , ) = interestRateModel
            .ratesConfig();

        for (uint256 i = 0; i < adjustmentPeriods; i++) {
            vm.warp(block.timestamp + adjustmentRate);
            eDAI.accrueInterest();
        }

        uint256 finalMultiplier = interestRateModel.vertexMultiplier();
        assertGe(
            finalMultiplier,
            WAD,
            "Multiplier should not fall below 1 WAD"
        );

        vm.stopPrank();
    }
}
