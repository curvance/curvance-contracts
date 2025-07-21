// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import "forge-std/console2.sol";

// ## Scenario 4: Mixed Auction and Regular Liquidations, with a mix of liquidateExact() and liquidate()
// - Setup: 4 users with varying positions
// - User 1: 1.9 strategyCBALRETH ($2,850), 2500 USDC debt
// - Action 1: Price drop by to ~$1,300, 
// - Action 2: User 1 is liquidated via regular liquidation using liquidateExact() 1/4 of their total debt
// - Action 3: User 1 is liquidated via regular liquidation using liquidateExact() 1/4 of their remaining debt
// - Action 3: User 1 has the rest of their debt liquidated via regular liquidation using liquidate()

contract LiquidateExactMix is TestBaseMarketManagerIsolated {

    address borrower1 = makeAddr("borrower1");

    address[] borrowers = [borrower1];

    uint256 borrowAmount = 2500e6;

    uint256 collateralAmountStart = 1.9e18;

    uint256 WAD_SQUARED = 1e36;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    // Auction parameters
    uint256 validPenalty = 1.04e18;
    uint256 closeFactor = 0.50e18;

    uint256[] amountToRepayPartial;

    event BadDebtRecognized(uint256 amount, address account);
    event Repay(uint256 amount, address payer, address account);

    function setUp() public override {
        super.setUp();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
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

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
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
        _createPositions();

        mockWethFeed.setMockAnswer(1300e8);
        mockRethFeed.setMockAnswer(1300e8);

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManagerIsolated.tokenData(address(strategyCBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;

        console2.log("SETUP COMPLETE");
    }

    uint256 outstandingDebtBefore;
    uint256 debtTokenPrice;
    uint256 collateralTokenPrice;
    uint256 quarterRatio = 0.25e18;
    uint256 cTokenExchangeRate;
    uint256 debtBalancesPreLiquidation;
    uint256 lFactorPreLiquidation;

    function test_liquidateExactMix() public {

        // ===== Cache general liquidation values =====

        cTokenExchangeRate = strategyCBALRETH.exchangeRate();

        outstandingDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        debtBalancesPreLiquidation = _getDebtBalancePreLiquidation(borrower1);

        lFactorPreLiquidation = _getLFactorPreLiquidation(borrower1);

        (,collateralTokenPrice, debtTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(borrower1, address(strategyCBALRETH), address(borrowableCUSDC));

        console2.log("debtTokenPrice", debtTokenPrice);
        console2.log("collateralTokenPrice", collateralTokenPrice);

        // ===== Cache first liquidation values =====
        amountToRepayPartial = new uint256[](1);

        // repay a quarter of the total debt
        amountToRepayPartial[0] = (debtBalancesPreLiquidation * quarterRatio) / WAD;

        console2.log("calculating first liquidation values");
        (uint256 maxAmount_liquidateExact_1, uint256 collateralLiquidated_liquidateExact_first, uint256 collateralRequired_liquidateExact_1) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
                debtTokenPrice, 
                collateralTokenPrice, 
                lFactorPreLiquidation,
                amountToRepayPartial[0],
                debtBalancesPreLiquidation
            );

        console2.log("maxAmount_liquidateExact_1", maxAmount_liquidateExact_1);
        console2.log("collateralLiquidated_liquidateExact_first", collateralLiquidated_liquidateExact_first);
        console2.log("collateralRequired_liquidateExact_1", collateralRequired_liquidateExact_1);

        uint256 badDebt_expected_liquidateExact_1 = _calculateBadDebt(
            debtBalancesPreLiquidation,
            amountToRepayPartial[0],
            collateralAmountStart,
            collateralRequired_liquidateExact_1,
            collateralLiquidated_liquidateExact_first,
            collateralTokenPrice,
            debtTokenPrice,
            cTokenExchangeRate
        );

        console2.log("badDebt_expected_liquidateExact_1", badDebt_expected_liquidateExact_1);

        uint256 totalDebtPaid_first = amountToRepayPartial[0] + badDebt_expected_liquidateExact_1;

        console2.log("totalDebtPaid_first", totalDebtPaid_first);

        uint256 remainingDebt_after_first = debtBalancesPreLiquidation - totalDebtPaid_first;

        console2.log("remainingDebt_after_first", remainingDebt_after_first);

        // ===== First liquidation using liquidateExact() =====

        address first_liquidator = makeAddr("first_liquidator");
        _prepareUSDC(first_liquidator, amountToRepayPartial[0]);

        vm.startPrank(first_liquidator);
        usdc.approve(address(borrowableCUSDC), amountToRepayPartial[0]);

        // expect bad debt emit and debt repaid
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(badDebt_expected_liquidateExact_1, first_liquidator);
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

        // Update lFactor (shouldn't change much).
        lFactorPreLiquidation = _getLFactorPreLiquidation(borrower1);

        // Update expected remaining collateral
        uint256 collateralAmount_after_first = collateralAmountStart - collateralLiquidated_liquidateExact_first;

        (uint256 maxAmount_liquidateExact_2, uint256 collateralLiquidated_liquidateExact_2, uint256 collateralRequired_liquidateExact_2) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
                debtTokenPrice, 
                collateralTokenPrice, 
                lFactorPreLiquidation,
                amountToRepayPartial[0],
                remainingDebt_after_first
            );

        uint256 badDebt_expected_liquidateExact_2 = _calculateBadDebt(
            remainingDebt_after_first,
            amountToRepayPartial[0],
            collateralAmount_after_first,
            collateralRequired_liquidateExact_2,
            collateralLiquidated_liquidateExact_2,
            collateralTokenPrice,
            debtTokenPrice,
            cTokenExchangeRate
        );

        uint256 totalDebtPaid_second = amountToRepayPartial[0] + badDebt_expected_liquidateExact_2;

        uint256 remainingDebt_after_second = remainingDebt_after_first - totalDebtPaid_second;

        // ====== Second liquidation using liquidateExact() =====

        address second_liquidator = makeAddr("second_liquidator");
        _prepareUSDC(second_liquidator, 100_000e6);

        vm.startPrank(second_liquidator);
        usdc.approve(address(borrowableCUSDC), amountToRepayPartial[0]);

        // expect bad debt emit and debt repaid
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(badDebt_expected_liquidateExact_2, second_liquidator);
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
        uint256 collateralAmount_after_second = collateralAmount_after_first - collateralLiquidated_liquidateExact_2;
        
        (uint256 maxAmount_liquidate_3, uint256 collateralLiquidated_liquidate_3, uint256 collateralRequired_liquidate_3) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction_Liquidate(
                debtTokenPrice, 
                collateralTokenPrice, 
                lFactorPreLiquidation,
                collateralAmount_after_second,  
                remainingDebt_after_second     
            );

        // For liquidate(), the actual debt amount liquidated is maxAmount_liquidate_3
        uint256 actualDebtToLiquidate_3 = maxAmount_liquidate_3;

        uint256 badDebt_expected_liquidate_3 = _calculateBadDebt(
            remainingDebt_after_second,  
            actualDebtToLiquidate_3,    // Use the actual debt amount that will be liquidated
            collateralAmount_after_second,
            collateralRequired_liquidate_3,
            collateralLiquidated_liquidate_3,
            collateralTokenPrice,
            debtTokenPrice,
            cTokenExchangeRate
        );

        uint256 totalDebtPaid_third = actualDebtToLiquidate_3 + badDebt_expected_liquidate_3;

        uint256 remainingDebt_after_third = remainingDebt_after_second - totalDebtPaid_third;

        address third_liquidator = makeAddr("third_liquidator");
        _prepareUSDC(third_liquidator, 100_000e6);

        vm.startPrank(third_liquidator);
        usdc.approve(address(borrowableCUSDC), 100_000e6);

        // expect bad debt emit and debt repaid
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(badDebt_expected_liquidate_3, third_liquidator);
        emit Repay(totalDebtPaid_third, third_liquidator, borrower1);

        borrowableCUSDC.liquidate(
            borrowers,
            address(strategyCBALRETH)
        );

       vm.stopPrank();

        // ===== Final Assertions =====

        // Verify borrower1's debt is fully liquidated.
        assertEq(borrowableCUSDC.debtBalance(borrower1), 0, "Borrower1 should have zero debt remaining");

        // Verify borrower1's collateral is fully liquidated.
        assertEq(strategyCBALRETH.balanceOf(borrower1), 0, "Borrower1 should have zero collateral remaining");

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

    function _getLiquidationValuesWithHigherPrecision_NonAuction_Liquidate(
        uint256 _debtTokenPrice,
        uint256 _collateralTokenPrice,
        uint256 _lFactor,
        uint256 _collateralAmounts,
        uint256 _borrowAmounts
    ) internal view returns (
        uint256 maxAmount, 
        uint256 collateralLiquidated,
        uint256 collateralRequired
    ) {
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
    
            if (_lFactor == 0) return (0,0,0);
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * _lFactor / WAD));
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * _lFactor) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * _debtTokenPrice * WAD * PRECISION_FACTOR) /
                (_collateralTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount = (auctionCFactor * borrowAmount) / WAD;
            
            // Calculate with extra precision
            collateralLiquidated = (maxAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (collateralLiquidated > _collateralAmounts) {
                // Use the contract's exact formula
                maxAmount = FixedPointMathLib.mulDivUp(
                    maxAmount,
                    _collateralAmounts,
                    collateralLiquidated
                );
                collateralLiquidated = _collateralAmounts;
            }
            
            // Use the contract's exact formula
            collateralRequired = (_borrowAmounts * highPrecisionD2C) / (WAD * PRECISION_FACTOR);


        return (maxAmount, collateralLiquidated, collateralRequired);
    }

    function _getLiquidationValuesWithHigherPrecision_NonAuction_LiquidateExact(
        uint256 _debtTokenPrice,
        uint256 _collateralTokenPrice,
        uint256 _lFactor,
        uint256 _debtAmount,
        uint256 _currentDebtBalance 
    ) internal view returns (
        uint256 maxAmount,
        uint256 collateralLiquidated,
        uint256 collateralRequired
    ) {
        uint256 auctionCFactor = baseCFactor + ((cFactorCurve * _lFactor) / WAD);
        uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * _lFactor) / WAD);
        
        // Match contract's exact calculation
        uint256 debtToCollateralMultiplier = (((auctionLiqIncentive * _debtTokenPrice * WAD_SQUARED) /
            (_collateralTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
        
        // Use the current debt balance instead of hardcoded debtBalancesPreLiquidation
        maxAmount = (auctionCFactor * _currentDebtBalance) / WAD;
        
        // collateralLiquidated should use the actual debt amount being liquidated
        collateralLiquidated = (_debtAmount * debtToCollateralMultiplier) / WAD_SQUARED;
        
        // collateralRequired should use the current debt balance
        collateralRequired = (_currentDebtBalance * debtToCollateralMultiplier) / WAD_SQUARED;
    }

    function _calculateBadDebt(
        uint256 _debtBalance,
        uint256 _debtAmount,
        uint256 _collateralAvailable,
        uint256 _collateralRequired,
        uint256 _collateralLiquidated,
        uint256 _collateralTokenUnderlyingPrice,
        uint256 _debtTokenUnderlyingPrice,
        uint256 _collateralTokenExchangeRate
    ) internal pure returns (uint256 badDebt) {

        if(_collateralRequired > _collateralAvailable) {
    
        badDebt = (_debtBalance - _debtAmount) -
        FixedPointMathLib.mulDivUp(
            ((_collateralAvailable - _collateralLiquidated) * _collateralTokenExchangeRate) / WAD,
            _collateralTokenUnderlyingPrice,
            (_debtTokenUnderlyingPrice * WAD) / 1e6
        );

        } else {
            return 0;
        }
        
    }
}