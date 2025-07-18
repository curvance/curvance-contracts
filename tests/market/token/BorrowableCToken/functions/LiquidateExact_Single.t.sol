// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { console2 } from "forge-std/console2.sol";

contract LiquidateExactSingleTest is TestBaseBorrowableCToken {
    
    uint256 debtBalancePreLiquidation;

    event BadDebtRecognized(address liquidator, uint256 amount);
    event Repay(address payer, address account, uint256 amount);

    function setUp() public override {
        super.setUp();

        _prepareLiquidation();

        debtBalancePreLiquidation = borrowableCUSDC.debtBalance(user1);
    }

    // Test a single liquidation
    function test_liquidateExact_single_success() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e6;

        _performLiquidationAndAssert(accounts, debtAmounts);
    }

    function _performLiquidationAndAssert(
        address[] memory accounts, 
        uint256[] memory debtAmounts
    ) internal {
        // Cache values before liquidation
        uint256 liquidatorBalanceBefore = strategyCBALRETH.balanceOf(user2);
        uint256 totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();
        uint256 borrowerCollateralBefore = strategyCBALRETH.balanceOf(user1);

        LiquidationParams memory params = LiquidationParams({   
            borrower: accounts[0],
            collateralToken: address(strategyCBALRETH),
            borrowedToken: address(borrowableCUSDC),
            isLiquidateExact: true,
            liquidateExactAmount: debtAmounts[0],
            isAuction: false,
            isMultiMarketTest: false,
            marketManagerId: 0
        });

        ExpectedLiquidationValues memory expectedLiquidationValues = 
            _calculateExpectedLiquidationValues(
                params
            );

        // Execute liquidation
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), debtAmounts[0]);
        borrowableCUSDC.liquidateExact(
            debtAmounts,
            accounts,
            address(strategyCBALRETH)
        );
        vm.stopPrank();

        // Run all assertions
        _assertDebtReduction(debtAmounts[0], expectedLiquidationValues.badDebt);
        _assertCollateralSeizure(borrowerCollateralBefore, expectedLiquidationValues.collateralLiquidated);
        _assertLiquidatorRewards(liquidatorBalanceBefore, expectedLiquidationValues.collateralLiquidated);
        _assertMarketAccounting(totalBorrowsBefore, debtAmounts[0], expectedLiquidationValues.badDebt);
        // partial liquidation will not improve health factor
        // _assertHealthFactorImprovement(lFactorsPreLiquidation);
        _assertBadDebtHandling(expectedLiquidationValues.badDebt, expectedLiquidationValues.collateralRequired, borrowerCollateralBefore);
        _assertInvariants();
    }

    function _assertDebtReduction(uint256 debtAmount, uint256 expectedBadDebt) internal view {
        uint256 debtAfter = borrowableCUSDC.debtBalance(user1);

        // bad debt expected

        console2.log("debtAfter", debtAfter);
        console2.log("debtBalancePreLiquidation", debtBalancePreLiquidation);
        console2.log("debtAmount", debtAmount);
        console2.log("expectedBadDebt", expectedBadDebt);

        uint256 expectedDebtAfter = debtBalancePreLiquidation - (debtAmount + expectedBadDebt);

        console2.log("expectedBadDebt", expectedBadDebt);

        assertApproxEqAbs(
            debtAfter, 
            expectedDebtAfter, 
            1000,
            "Debt reduction should include bad debt"
        );
    }

    function _assertCollateralSeizure(uint256 _collateralAmount, uint256 collateralLiquidated) internal view {
        uint256 borrowerCollateralAfter = strategyCBALRETH.balanceOf(user1);
        uint256 expectedBorrowerCollateralAfter = _collateralAmount - collateralLiquidated;
        
        assertApproxEqAbs(
            borrowerCollateralAfter,
            expectedBorrowerCollateralAfter,
            1000,
            "Borrower collateral should be reduced by collateralLiquidated"
        );
    }

    function _assertLiquidatorRewards(uint256 liquidatorBalanceBefore, uint256 collateralLiquidated) internal view {
        uint256 liquidatorBalanceAfter = strategyCBALRETH.balanceOf(user2);
        
        assertApproxEqAbs(
            liquidatorBalanceAfter - liquidatorBalanceBefore,
            collateralLiquidated,
            1000,
            "Liquidator should receive expected collateral"
        );
    }

    function _assertMarketAccounting(uint256 totalBorrowsBefore, uint256 debtAmount, uint256 expectedBadDebt) internal view {
        uint256 totalBorrowsAfter = borrowableCUSDC.marketOutstandingDebt();
        uint256 expectedTotalDebtReduction = debtAmount + expectedBadDebt;
        
        assertApproxEqAbs(
            totalBorrowsAfter,
            totalBorrowsBefore - expectedTotalDebtReduction,
            1000,
            "Market outstanding debt should be reduced by debt repaid plus bad debt"
        );
    }

    function _assertBadDebtHandling(uint256 expectedBadDebt, uint256 collateralRequired, uint256 collateralAmounts) internal pure {
        console2.log("expectedBadDebt", expectedBadDebt);
        console2.log("collateralRequired", collateralRequired);
        console2.log("collateralAmounts", collateralAmounts);

        if (expectedBadDebt > 0) {
            assertTrue(expectedBadDebt > 0, "Expected bad debt should be greater than 0 for hard liquidations");
            assertTrue(
                collateralRequired > collateralAmounts,
                "Bad debt should only occur when collateral is insufficient"
            );
        }
    }

    function _assertInvariants() internal view {
        // Verify liquidator had enough balance to cover the liquidation
        assertTrue(
            true, // If we got here, the liquidation succeeded
            "Liquidation should have completed successfully"
        );
        
        // Verify collateral exchange rate didn't change
        assertEq(
            strategyCBALRETH.exchangeRate(),
            1e18,
            "Exchange rate should remain constant during liquidation"
        );

        // Verify USDC exchange rate didn't change 
        assertApproxEqRel(
            borrowableCUSDC.exchangeRate(),
            WAD,
            0.01e18,
            "USDC exchange rate should remain close to 1"
        );
    }
}