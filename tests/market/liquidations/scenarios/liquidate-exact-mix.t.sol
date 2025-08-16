// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

// ## Scenario 4: Mixed Auction and Regular Liquidations, with a mix of liquidateExact() and liquidate()
// - Setup: 4 users with varying positions
// - User 1: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt
// - Action 1: Price drop by to ~$1,300, 
// - Action 2: User 1 is liquidated via regular liquidation using liquidateExact() 1/4 of their total debt
// - Action 3: User 1 is liquidated via regular liquidation using liquidateExact() 1/4 of their remaining debt
// - Action 3: User 1 has the rest of their debt liquidated via regular liquidation using liquidate()

contract LiquidateExactMix is TestBaseLiquidations {

    address borrower1 = makeAddr("borrower1");
    uint256 collateralAmountStart = 1.9e18;
    uint256 borrowAmount = 2500e6;
    address[] borrowers = [borrower1];
    uint256[] amountToRepayPartial;
    
    // Auction parameters
    uint256 validPenalty = 1.04e18;
    uint256 closeFactor = 0.50e18;

    event BadDebtRecognized(uint256 amount, address account);
    event Repay(uint256 amount, address payer, address account);

    function setUp() public override {
        super.setUp();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
        );

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(1500e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        _prepareBALRETH(user1, _ONE + 77777);

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigHighValues(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint borrowableCUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        mockWethFeed.setMockAnswer(2000e8);
        mockRethFeed.setMockAnswer(2000e8);
        _createPositions();

        mockWethFeed.setMockAnswer(1300e8);
        mockRethFeed.setMockAnswer(1300e8);

        console2.log("SETUP COMPLETE");
    }

    uint256 outstandingDebtBefore;
    uint256 quarterRatio = 0.25e18;
    uint256 debtBalancesPreLiquidation;
    uint256 lFactorPreLiquidation;

    function test_liquidateExactMix() public {

        skip(4 weeks);
        _refreshMockFeeds();
        borrowableCUSDC.accrueIfNeeded();

        // ===== Cache general liquidation values =====

        outstandingDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        debtBalancesPreLiquidation = _getDebtBalancePreLiquidation(borrower1);

        // ===== Cache first liquidation values =====
        amountToRepayPartial = new uint256[](1);

        // repay a quarter of the total debt
        amountToRepayPartial[0] = (debtBalancesPreLiquidation * quarterRatio) / WAD;

        console2.log("calculating first liquidation values");

        ExpectedLiquidationValues memory expectedLiqValues_first = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: borrower1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: true,
                liquidateExactAmount: amountToRepayPartial[0],
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        uint256 totalDebtPaid_first = amountToRepayPartial[0] + expectedLiqValues_first.badDebt;

        uint256 remainingDebt_after_first = debtBalancesPreLiquidation - totalDebtPaid_first;

        // ===== First liquidation using liquidateExact() =====

        address first_liquidator = makeAddr("first_liquidator");
        _prepareUSDC(first_liquidator, amountToRepayPartial[0]);

        vm.startPrank(first_liquidator);
        usdc.approve(address(borrowableCUSDC), amountToRepayPartial[0]);

        // expect bad debt emit and debt repaid
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(expectedLiqValues_first.badDebt, first_liquidator);
        emit Repay(totalDebtPaid_first, first_liquidator, borrower1);

        borrowableCUSDC.liquidateExact(
            amountToRepayPartial,
            borrowers,
            address(strategyCBALRETH)
        );

        vm.stopPrank();

        // ===== Cache second liquidation values =====

        // Repay a quarter of the remaining debt.
        amountToRepayPartial[0] = (remainingDebt_after_first * quarterRatio) / WAD;

        console2.log("amountToRepayPartial after second liquidation" ,amountToRepayPartial[0] );

        // Update lFactor (shouldn't change much).
        lFactorPreLiquidation = _getLFactorPreLiquidation(borrower1);

        // Update expected remaining collateral
        uint256 collateralAmount_after_first = collateralAmountStart - expectedLiqValues_first.collateralLiquidated;

        ExpectedLiquidationValues memory expectedLiqValues_second = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: borrower1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: true,
                liquidateExactAmount: amountToRepayPartial[0],
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        console2.log("amountToRepayPartial[0]", amountToRepayPartial[0]);
        console2.log("expectedLiqValues_second.badDebt", expectedLiqValues_second.badDebt);

        uint256 totalDebtPaid_second = amountToRepayPartial[0] + expectedLiqValues_second.badDebt;

        uint256 remainingDebt_after_second = remainingDebt_after_first - totalDebtPaid_second;

        // ====== Second liquidation using liquidateExact() =====

        address second_liquidator = makeAddr("second_liquidator");
        _prepareUSDC(second_liquidator, 100_000e6);

        vm.startPrank(second_liquidator);
        usdc.approve(address(borrowableCUSDC), amountToRepayPartial[0]);

        // expect bad debt emit and debt repaid
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(expectedLiqValues_second.badDebt, second_liquidator);
        emit Repay(totalDebtPaid_second, second_liquidator, borrower1);

        // The second liquidation should have the same expected result as the first

        borrowableCUSDC.liquidateExact(
            amountToRepayPartial,
            borrowers,
            address(strategyCBALRETH)
        );

        vm.stopPrank();

        // ===== Cache third liquidation values =====

        // Update lFactor (shouldn't change much).
        lFactorPreLiquidation = _getLFactorPreLiquidation(borrower1);

        // Update expected remaining collateral.
        uint256 collateralAmount_after_second = collateralAmount_after_first - expectedLiqValues_second.collateralLiquidated;

        ExpectedLiquidationValues memory expectedLiqValues_third = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: borrower1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        uint256 totalDebtPaid_third = expectedLiqValues_third.debtRepaid + expectedLiqValues_third.badDebt;

        console2.log("remainingDebt_after_second", remainingDebt_after_second);
        console2.log("totalDebtPaid_third", totalDebtPaid_third);

        uint256 remainingDebt_after_third = remainingDebt_after_second - totalDebtPaid_third;

        address third_liquidator = makeAddr("third_liquidator");
        _prepareUSDC(third_liquidator, 100_000e6);

        vm.startPrank(third_liquidator);
        usdc.approve(address(borrowableCUSDC), 100_000e6);

        // expect bad debt emit and debt repaid
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(expectedLiqValues_third.badDebt, third_liquidator);
        emit Repay(totalDebtPaid_third, third_liquidator, borrower1);

        borrowableCUSDC.liquidate(
            borrowers,
            address(strategyCBALRETH)
        );

       vm.stopPrank();

        // ===== Final Assertions =====

        uint256 collateralAmountAfterThird = collateralAmount_after_second - expectedLiqValues_third.collateralLiquidated;

        // Verify borrower1's debt is fully liquidated.
        assertEq(borrowableCUSDC.debtBalance(borrower1), 0, "Borrower1 should have zero debt remaining");

        // Verify borrower1's collateral is fully liquidated.
        assertEq(strategyCBALRETH.balanceOf(borrower1), 0, "Borrower1 should have zero collateral remaining");
        assertEq(strategyCBALRETH.balanceOf(borrower1), collateralAmountAfterThird, "double check to make sure the test accounting aligns fully");

        // Verify total outstanding debt decreased appropriately.
        uint256 outstandingDebtAfter = borrowableCUSDC.marketOutstandingDebt();
        assertLt(outstandingDebtAfter, outstandingDebtBefore, "Total outstanding debt should have decreased");

        // Verify the position is no longer liquidatable.
        (uint256 lFactorFinal,,) = marketManagerIsolated.liquidationStatusOf(
            borrower1,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );
        assertEq(lFactorFinal, 0, "Position should no longer be liquidatable");

        // Verify remaining debt calculation was correct
        assertApproxEqAbs(remainingDebt_after_third, 0, 1, "Remaining debt should be approximately zero");
    }

    function _createPositions() internal {
        _prepareBALRETH(borrower1, collateralAmountStart);

        vm.startPrank(borrower1);
        balRETH.approve(address(strategyCBALRETH), collateralAmountStart);
        strategyCBALRETH.depositAsCollateral(collateralAmountStart, borrower1);
        borrowableCUSDC.borrow(borrowAmount, borrower1);
        vm.stopPrank();
    }

    function _getLFactorPreLiquidation(address _borrower) internal view returns (uint256 lFactor) {
            (lFactor,,) = marketManagerIsolated.liquidationStatusOf(
                _borrower,
                address(strategyCBALRETH),
                address(borrowableCUSDC)
            );

        return lFactor;
    }

    function _getDebtBalancePreLiquidation(address _borrower) internal view returns (uint256 debtBalance) {
        debtBalance = borrowableCUSDC.debtBalance(_borrower);
    }

}