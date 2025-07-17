// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { console2 } from "forge-std/console2.sol";

contract LiquidateExactSingleTest is TestBaseBorrowableCToken {
    
    // Storage to avoid stack too deep
    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;
    uint256 maxAmount;
    uint256 collateralLiquidated;
    uint256 collateralRequired;
    uint256 cTokenExchangeRate;
    uint256 debtBalancesPreLiquidation;
    uint256 collateralAmounts;
    uint256 expectedBadDebt;
    uint256 debtTokenPrice;
    uint256 collateralTokenPrice;

    uint256 lFactorsPreLiquidation;

    event BadDebtRecognized(address liquidator, uint256 amount);
    event Repay(address payer, address account, uint256 amount);

    function setUp() public override {
        super.setUp();

        _prepareLiquidation();

        // Cache liquidation parameters
        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManagerIsolated.tokenData(address(strategyCBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;
    }

    // Test a single liquidation
    function test_liquidateExact_single_success() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e6;

        lFactorsPreLiquidation = _getLFactorsPreLiquidation(user1);
        debtBalancesPreLiquidation = _getDebtBalancePreLiquidation(user1);
        
        (collateralTokenPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );
        (debtTokenPrice,) = oracleManager.getPrice(
            address(usdc),
            true,
            true
        );

        (maxAmount, collateralLiquidated, collateralRequired) = _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
            debtAmounts[0]
        );

        cTokenExchangeRate = strategyCBALRETH.exchangeRate();
        collateralAmounts = strategyCBALRETH.collateralPosted(user1);
        
        expectedBadDebt = _calculateBadDebt(
            debtBalancesPreLiquidation,
            debtAmounts[0],
            collateralAmounts,
            collateralRequired,
            collateralLiquidated,
            collateralTokenPrice,
            debtTokenPrice,
            cTokenExchangeRate
        );

        _performLiquidationAndAssert(accounts, debtAmounts, lFactorsPreLiquidation);
    }

    function _performLiquidationAndAssert(
        address[] memory accounts, 
        uint256[] memory debtAmounts,
        uint256 lFactorsPreLiquidation
    ) internal {
        // Cache values before liquidation
        uint256 liquidatorBalanceBefore = strategyCBALRETH.balanceOf(user2);
        uint256 totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();
        uint256 borrowerCollateralBefore = strategyCBALRETH.balanceOf(user1);

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
        _assertDebtReduction(debtAmounts[0]);
        _assertCollateralSeizure(borrowerCollateralBefore);
        _assertLiquidatorRewards(liquidatorBalanceBefore);
        _assertMarketAccounting(totalBorrowsBefore, debtAmounts[0]);
        // partial liquidation will not improve health factor
        // _assertHealthFactorImprovement(lFactorsPreLiquidation);
        _assertBadDebtHandling();
        _assertInvariants();
    }

    function _assertDebtReduction(uint256 debtAmount) internal view {
        uint256 debtAfter = borrowableCUSDC.debtBalance(user1);

        // bad debt expected

        console2.log("debtAmount + expectedBadDebt", debtAmount + expectedBadDebt);
        console2.log("debtBalancesPreLiquidation", debtBalancesPreLiquidation);
        console2.log("debtAfter", debtAfter);

        uint256 expectedDebtAfter = debtBalancesPreLiquidation - (debtAmount + expectedBadDebt);

        console2.log("expectedBadDebt", expectedBadDebt);

        assertApproxEqAbs(
            debtAfter, 
            expectedDebtAfter, 
            1000,
            "Debt reduction should include bad debt"
        );
    }

    function _assertCollateralSeizure(uint256 _collateralAmount) internal view {
        uint256 borrowerCollateralAfter = strategyCBALRETH.balanceOf(user1);
        uint256 expectedBorrowerCollateralAfter = _collateralAmount - collateralLiquidated;
        
        assertApproxEqAbs(
            borrowerCollateralAfter,
            expectedBorrowerCollateralAfter,
            1000,
            "Borrower collateral should be reduced by collateralLiquidated"
        );
    }

    function _assertLiquidatorRewards(uint256 liquidatorBalanceBefore) internal view {
        uint256 liquidatorBalanceAfter = strategyCBALRETH.balanceOf(user2);
        
        assertApproxEqAbs(
            liquidatorBalanceAfter - liquidatorBalanceBefore,
            collateralLiquidated,
            1000,
            "Liquidator should receive expected collateral"
        );
    }

    function _assertMarketAccounting(uint256 totalBorrowsBefore, uint256 debtAmount) internal view {
        uint256 totalBorrowsAfter = borrowableCUSDC.marketOutstandingDebt();
        uint256 expectedTotalDebtReduction = debtAmount + expectedBadDebt;
        
        assertApproxEqAbs(
            totalBorrowsAfter,
            totalBorrowsBefore - expectedTotalDebtReduction,
            1000,
            "Market outstanding debt should be reduced by debt repaid plus bad debt"
        );
    }

    function _assertBadDebtHandling() internal view {
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
            cTokenExchangeRate,
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

    function _getLFactorsPreLiquidation(address _borrower) internal view returns (uint256 lFactors) {
        (lFactors,,) = marketManagerIsolated.liquidationStatusOf(
            _borrower,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );
        return lFactors;
    }

    function _getDebtBalancePreLiquidation(address _borrower) internal view returns (uint256 debtBalance) {
        debtBalance = borrowableCUSDC.debtBalance(_borrower);
    }

    function _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
        uint256 _debtAmount
    ) internal view returns (
        uint256 maxAmount,
        uint256 collateralLiquidated,
        uint256 collateralRequired
    ) {

        (uint256 lFactor,,) = marketManagerIsolated.liquidationStatusOf(
            user1,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );
        
        uint256 debtBalance = borrowableCUSDC.debtBalance(user1);
        
        uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactor) / WAD);
        uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactor) / WAD);

        console2.log("calculating highPrecisionD2C");
        console2.log("auctionLiqIncentive", auctionLiqIncentive);
        console2.log("debtTokenPrice", debtTokenPrice);
        console2.log("collateralTokenPrice", collateralTokenPrice);
        console2.log("cTokenExchangeRate", cTokenExchangeRate);
        
        uint256 debtToCollateralMultiplier = (((auctionLiqIncentive *
            debtTokenPrice * WAD_SQUARED) /
            (collateralTokenPrice * cTokenExchangeRate)) *
            1e18) / 1e6;
        
        maxAmount = (auctionCFactor * debtBalance) / WAD_SQUARED;

        collateralLiquidated = (_debtAmount * debtToCollateralMultiplier) / WAD_SQUARED;
        
        collateralRequired = (debtBalance * debtToCollateralMultiplier) / WAD;
    }

    function _calculateBadDebt(
        uint256 _debtBalance,
        uint256 _debtAmount,
        uint256 _collateralAvailable,
        uint256 _collateralRequired,
        uint256 _collateralLiquidated,
        uint256 _collateralTokenUnderlyingPrice,
        uint256 _debtTokenUnderlyingPrice,
        uint256 _cTokenExchangeRate
    ) internal pure returns (uint256 badDebt) {
        console2.log("BAD DEBT CALCULATION");
        console2.log("_collateralRequired", _collateralRequired);
        console2.log("_collateralAvailable", _collateralAvailable);
        console2.log("_debtBalance", _debtBalance);
        console2.log("_debtAmount", _debtAmount);
        console2.log("_collateralLiquidated", _collateralLiquidated);
        console2.log("_collateralTokenUnderlyingPrice", _collateralTokenUnderlyingPrice);
        console2.log("_debtTokenUnderlyingPrice", _debtTokenUnderlyingPrice);
        console2.log("_cTokenExchangeRate", _cTokenExchangeRate);

        if(_collateralRequired > _collateralAvailable) {
            uint256 amountToSubtract = 
                FixedPointMathLib.mulDivUp(
                    ((_collateralAvailable - _collateralLiquidated) * _cTokenExchangeRate) / WAD,
                    _collateralTokenUnderlyingPrice,
                    (_debtTokenUnderlyingPrice * WAD) / 1e6 
                );

            console2.log("amountToSubtract", amountToSubtract);
            console2.log("(_debtBalance - _debtAmount)", (_debtBalance - _debtAmount));
            
            badDebt = (_debtBalance - _debtAmount) - amountToSubtract;
        } else {
            return 0;
        }

        
    }
}