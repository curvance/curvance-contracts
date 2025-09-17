// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

// ## Scenario: Mixed Collateral Results with Same Debt, Different Collateral, all using liquidate() function
// - Setup: 4 users with same debt but different collateral (creating natural risk diversity)
// - User 1: 2.2 Pendle wstETH LP tokens (~$22,600 initial value), 10,000 USDC debt (very healthy)
// - User 2: 1.8 Pendle wstETH LP tokens (~$18,500 initial value), 10,000 USDC debt (healthy - 54% LTV)
// - User 3: 1.5 Pendle wstETH LP tokens (~$15,400 initial value), 10,000 USDC debt (borderline - 65% LTV)
// - User 4: 1.4 Pendle wstETH LP tokens (~$14,400 initial value), 10,000 USDC debt (very risky - 69% LTV)
// - Action: Price drop to $6,500 per token (37% drop, realistic market crash)
// - Expected: Users 3 and 4 liquidated, Users 1 and 2 remain healthy
//      User 3 has a soft liquidation, so no bad debt.
//      User 4 has a hard liquidation which accrues bad debt.

contract MixedCollateral is TestBaseLiquidations {

    address borrower1 = address(0x0000000000000000000000000000000000000001);
    address borrower2 = address(0x0000000000000000000000000000000000000002);
    address borrower3 = address(0x0000000000000000000000000000000000000003);
    address borrower4 = address(0x0000000000000000000000000000000000000004);

    uint256 borrowAmount = 10_000e6; // All users borrow same amount
    address[] borrowers = [borrower1, borrower2, borrower3, borrower4];
    uint256[] collateralAmounts = [2.2e18, 1.8e18, 1.5e18, 1.4e18]; // Different collateral = different risk

    event Repay(uint256 assets, address payer, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);

    function setUp() public override {
        super.setUp();

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        deal(address(LP_wstETH_24Dec2025), user1, _ONE + 77777);

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigHighValues(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigLowValues(address(borrowableCUSDC), 100_000e18, 100_000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10e18);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _createPositions();

        _setPendleStEthLpPrice(6500e8);

        console2.log("SETUP COMPLETE");
    }

    function test_mixedCollateral() public {

        _prepareUSDC(address(this), 100000e6);

        // ===== Cache liquidation values =====

        uint256[] memory lFactorsPreLiquidation = _getLFactorsPreLiquidation();
        uint256[] memory debtBalancesPreLiquidation = _getDebtBalancePreLiquidation();

        console2.log("Borrower 1 lFactor", lFactorsPreLiquidation[0]);
        console2.log("Borrower 2 lFactor", lFactorsPreLiquidation[1]);
        console2.log("Borrower 3 lFactor", lFactorsPreLiquidation[2]);
        console2.log("Borrower 4 lFactor", lFactorsPreLiquidation[3]);

        (uint256 collateralTokenPrice,uint256 debtTokenPrice) =
            oracleManager.getPriceIsolatedPair(
                address(pendleStrategyCTokenSTETH),
                address(borrowableCUSDC),
                2
            );

        console2.log("debtTokenPrice", debtTokenPrice);
        console2.log("collateralTokenPrice", collateralTokenPrice);

        uint256 expectedTotalBadDebt;
        ExpectedLiquidationValues[] memory expectedLiqValues = new ExpectedLiquidationValues[](4);

        for(uint i; i < 4; i++) {

            expectedLiqValues[i] = _calculateExpectedLiquidationValues(
                LiquidationParams({
                    borrower: borrowers[i],
                    collateralToken: address(pendleStrategyCTokenSTETH),
                    borrowedToken: address(borrowableCUSDC),
                    isLiquidateExact: false,
                    liquidateExactAmount: 0,
                    isAuction: false,
                    isMultiMarketTest: false,
                    marketManagerId: 0
                })
            );

            expectedTotalBadDebt += expectedLiqValues[i].badDebt;
        }

        uint256 totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        // ===== Liquidate =====

        borrowableCUSDC.approve(address(marketManagerIsolated), 100000e6);

        // Assert BadDebtRecognized event is emitted with expected total bad debt
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(expectedTotalBadDebt, address(this) );
        emit Repay(expectedLiqValues[2].debtRepaid + expectedLiqValues[2].badDebt, address(this), borrowers[2]);
        emit Repay(expectedLiqValues[3].debtRepaid + expectedLiqValues[3].badDebt, address(this), borrowers[3]);
        
        borrowableCUSDC.liquidate(
            borrowers,
            address(pendleStrategyCTokenSTETH)
        );

        // ===== Validate =====

        // Verify healthy accounts (1 and 2) are not liquidated
        assertEq(borrowableCUSDC.debtBalance(borrowers[0]), debtBalancesPreLiquidation[0], "Healthy account 1 shouldn't be liquidated");
        assertEq(borrowableCUSDC.debtBalance(borrowers[1]), debtBalancesPreLiquidation[1], "Healthy account 2 shouldn't be liquidated");

        // Verify account 4 is hard liquidated
        assertEq(borrowableCUSDC.debtBalance(borrowers[3]), 0, "Borrower 4 should be hard liquidated");

        // Verify account 3 is soft liquidated
        assertEq(borrowableCUSDC.debtBalance(borrowers[2]), debtBalancesPreLiquidation[2] - expectedLiqValues[2].debtRepaid, "Borrower 3 should be soft liquidated");
        
        // Assert collateral is reduced by liquidatedCollateral
        assertApproxEqAbs(
            pendleStrategyCTokenSTETH.balanceOf(borrowers[3]),
            collateralAmounts[3] - expectedLiqValues[3].collateralLiquidated,
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            pendleStrategyCTokenSTETH.balanceOf(borrowers[2]),
            collateralAmounts[2] - expectedLiqValues[2].collateralLiquidated,
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        // Assert Total borrows is reduced by the amount of debt repaid

        uint256 totalDebtRepaid = borrowAmount + expectedLiqValues[2].debtRepaid; // User 3 is soft liquidated, using borrowAmount as user 4 who is hard liquidated

        assertApproxEqAbs(
            borrowableCUSDC.marketOutstandingDebt(),
            totalBorrowsBefore - totalDebtRepaid,
            100, // Small tolerance
            "Incorrect totalBorrows after liquidation"
        );

        // Verify liquidator received the expected collateral
        uint256 expectedLiquidatorBalance = expectedLiqValues[2].collateralLiquidated + expectedLiqValues[3].collateralLiquidated;
        assertApproxEqAbs(
            pendleStrategyCTokenSTETH.balanceOf(address(this)),
            expectedLiquidatorBalance,
            1000,
            "Liquidator didn't receive expected collateral"
        );

        // Verify lFactors
        for(uint i = 2; i < 4; i++) {
            (, , , uint256 lFactorAfter) = _liquidationValuesOfHelper(marketManagerIsolated, borrowers[i]);

            console2.log("borrower", i, "lFactor", lFactorAfter);

            if(borrowableCUSDC.debtBalance(borrowers[i]) == 0) {
                assertTrue(lFactorAfter < lFactorsPreLiquidation[i], "Heath factor should be zero after full liquidation");
            }
        }
    }

    function _createPositions() internal {
        deal(address(LP_wstETH_24Dec2025), borrower1, collateralAmounts[0]);
        deal(address(LP_wstETH_24Dec2025), borrower2, collateralAmounts[1]);
        deal(address(LP_wstETH_24Dec2025), borrower3, collateralAmounts[2]);
        deal(address(LP_wstETH_24Dec2025), borrower4, collateralAmounts[3]);

        vm.startPrank(borrower1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), collateralAmounts[0]);
        pendleStrategyCTokenSTETH.depositAsCollateral(collateralAmounts[0], borrower1);
        borrowableCUSDC.borrow(borrowAmount, borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), collateralAmounts[1]);
        pendleStrategyCTokenSTETH.depositAsCollateral(collateralAmounts[1], borrower2);
        borrowableCUSDC.borrow(borrowAmount, borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), collateralAmounts[2]);
        pendleStrategyCTokenSTETH.depositAsCollateral(collateralAmounts[2], borrower3);
        borrowableCUSDC.borrow(borrowAmount, borrower3);
        vm.stopPrank();

        vm.startPrank(borrower4);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), collateralAmounts[3]);
        pendleStrategyCTokenSTETH.depositAsCollateral(collateralAmounts[3], borrower4);
        borrowableCUSDC.borrow(borrowAmount, borrower4);
        vm.stopPrank();

    }

    function _getLFactorsPreLiquidation() internal returns (uint256[] memory lFactors) {
        lFactors = new uint256[](4);

        for(uint i; i < 4; i++) {
            (, , , lFactors[i]) = _liquidationValuesOfHelper(marketManagerIsolated, borrowers[i]);
        }

        return lFactors;
    }

    function _getDebtBalancePreLiquidation() internal view returns (uint256[] memory debtBalances) {
        debtBalances = new uint256[](4);
        for(uint i; i < 4; i++) {
            debtBalances[i] = borrowableCUSDC.debtBalance(borrowers[i]);
        }
        return debtBalances;
    }
}