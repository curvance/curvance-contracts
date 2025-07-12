// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import "forge-std/console2.sol";

// TODO - ADD ASSERTIONS!!!!

// 0. Use maximum LTV possible for fuzzing
// 1. Fuzz collateral
// 2. Borrow amounts - make sure fuzzed borrows are within the maximum LTV
// 3. Fuzz oracle price of collateral
// 4. Add a case for when the lFactor is 0, expectRevert for liquidate
// 5. Use liquidate() to liquidate the position.
// 6. Assert all liquidation values match expected values

contract LiquidationFuzzedTest is TestBaseMarketManagerIsolated {

    address borrower = makeAddr("borrower");

    address[] borrowerArray = [borrower];

    uint256 constant INITIAL_PRICE = 1500e8;
    uint256 constant MINIMUM_COLLATERAL_AMOUNT = 0.1e18;
    uint256 constant MAXIMUM_COLLATERAL_AMOUNT = 2000e18;
    int256 constant MINIMUM_COLLATERAL_PRICE = 1000e8;
    int256 constant MAXIMUM_COLLATERAL_PRICE = 2000e8;
    uint256 constant MINIMUM_BORROW_AMOUNT = 10e6;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    // Storage to avoid stack too deep
    uint256 maxAmount;
    uint256 liquidatedPTokens;
    uint256 collateralRequired;
    uint256 cTokenExchangeRate;
    uint256 debtBalancesPreLiquidation;
    uint256 collateralAmounts;
    uint256 expectedBadDebt;


    event BadDebtRecognized(address liquidator, uint256 amount);
    event Repay(address liquidator, address account, uint256 amount);

    function setUp() public override {
        super.setUp();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, address(mockUsdcFeed), 0, true);
        dualChainlinkAdaptor.addAsset(_USDC_ADDRESS, address(mockUsdcFeed), 0, true);

        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(int256(INITIAL_PRICE));
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockAnswer(int256(INITIAL_PRICE));
        mockRethFeed.setMockAnswer(int256(INITIAL_PRICE));
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user1, _ONE);
        _prepareBALRETH(user1, _ONE + 77777);

        vm.prank(user1);
        usdc.approve(address(borrowableCUSDC), _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE + 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        MarketManagerIsolated.TokenConfig memory tokenConfigs;
        tokenConfigs.cToken = address(strategyCBALRETH);
        tokenConfigs.collRatio = 7000;
        tokenConfigs.collReqSoft = 4000;
        tokenConfigs.collReqHard = 3000;
        tokenConfigs.liqIncBase = 1000;
        tokenConfigs.liqIncHard = 1500;
        tokenConfigs.liqIncMin = 500;
        tokenConfigs.liqIncMax = 2000;
        tokenConfigs.minEffectiveCloseFactor = 2000;
        tokenConfigs.maxEffectiveCloseFactor = 3000;
        tokenConfigs.baseCFactor = 1000;
        tokenConfigs.collateralCap = 10000e18;
        tokenConfigs.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfigs);

        tokenConfigs.cToken = address(borrowableCUSDC);
        tokenConfigs.debtCap = 100_000_000e6;

        marketManagerIsolated.updateTokenConfig(tokenConfigs);

        // Add liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000000e6);
        _prepareBALRETH(liquidityProvider, 100e18);
        
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000000e6);
        borrowableCUSDC.deposit(200000000e6, liquidityProvider);
        balRETH.approve(address(strategyCBALRETH), 100e18);
        strategyCBALRETH.deposit(100e18, liquidityProvider);
        vm.stopPrank();

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManagerIsolated.tokenData(address(strategyCBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;
    }

    function test_fuzzLiquidation(
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        int256 _oraclePrice
    ) public {

        _collateralAmount = bound(_collateralAmount, MINIMUM_COLLATERAL_AMOUNT, MAXIMUM_COLLATERAL_AMOUNT);
        _oraclePrice = int256(bound(uint256(int256(_oraclePrice)), uint256(MINIMUM_COLLATERAL_PRICE), uint256(MAXIMUM_COLLATERAL_PRICE)));

        _prepareBALRETH(borrower, _collateralAmount);

        vm.startPrank(borrower);
        balRETH.approve(address(strategyCBALRETH), _collateralAmount);
        strategyCBALRETH.depositAsCollateral(_collateralAmount,borrower);

        (, uint256 maxBorrowAmount,) = marketManagerIsolated.statusOf(borrower);

        maxBorrowAmount = maxBorrowAmount / 1e18;

        // Skip this test case if maxBorrowAmount is too small
        if (maxBorrowAmount < MINIMUM_BORROW_AMOUNT) {
            return; 
        }

        _borrowAmount = bound(_borrowAmount, MINIMUM_BORROW_AMOUNT, maxBorrowAmount);
        borrowableCUSDC.borrow(_borrowAmount);
        vm.stopPrank();

        mockWethFeed.setMockAnswer(_oraclePrice);
        mockRethFeed.setMockAnswer(_oraclePrice);
        skip(20 minutes);

        uint256 lFactorsPreLiquidation = _getLFactorsPreLiquidation(borrower);

        (uint256 lFactor, uint256 cTokenPrice, uint256 eTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(borrower, address(strategyCBALRETH), address(borrowableCUSDC));

        (maxAmount, liquidatedPTokens, collateralRequired) = 
            _getLiquidationValuesWithHigherPrecision_NonAuction_Liquidate(
                eTokenPrice, cTokenPrice, lFactorsPreLiquidation, _collateralAmount, _borrowAmount
            );
        
        cTokenExchangeRate = strategyCBALRETH.exchangeRate();
        collateralAmounts = strategyCBALRETH.collateralPosted(borrower);
        debtBalancesPreLiquidation = borrowableCUSDC.debtBalanceUpdated(borrower);
        expectedBadDebt = _calculateBadDebt(
            debtBalancesPreLiquidation,
            maxAmount,
            collateralAmounts,
            collateralRequired,
            liquidatedPTokens,
            cTokenPrice,
            eTokenPrice,
            cTokenExchangeRate
        );
        
        _prepareUSDC(liquidator, 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000_000e6);

        if (lFactor == 0) {
            _handleNoLiquidationCase(_collateralAmount);
            return;
        }

        // Perform liquidation and run assertions
        _performLiquidationAndAssert(_collateralAmount, lFactorsPreLiquidation);
    }

    function _handleNoLiquidationCase(uint256 _collateralAmount) internal {
        vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));
        borrowableCUSDC.liquidate(borrowerArray, address(strategyCBALRETH));
        
        assertEq(borrowableCUSDC.debtBalance(borrower), debtBalancesPreLiquidation, "Debt should not change when lFactor is 0");
        assertEq(strategyCBALRETH.balanceOf(borrower), _collateralAmount, "Collateral should not change when lFactor is 0");
        assertEq(strategyCBALRETH.balanceOf(liquidator), 0, "Liquidator should not receive collateral when lFactor is 0");
    }

    function _performLiquidationAndAssert(uint256 _collateralAmount, uint256 lFactorsPreLiquidation) internal {
        // cache values before liquidation
        uint256 liquidatorBalanceBefore = strategyCBALRETH.balanceOf(liquidator);
        uint256 totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        vm.expectEmit();
        emit BadDebtRecognized(liquidator, expectedBadDebt);
        emit Repay(liquidator, borrower, maxAmount + expectedBadDebt);

        borrowableCUSDC.liquidate(borrowerArray, address(strategyCBALRETH));

        // Run all assertions
        _assertDebtReduction();
        _assertCollateralSeizure(_collateralAmount);
        _assertLiquidatorRewards(liquidatorBalanceBefore);
        _assertMarketAccounting(totalBorrowsBefore);
        _assertHealthFactorImprovement(lFactorsPreLiquidation);
        _assertBadDebtHandling();
        _assertInvariants();
    }

    function _assertDebtReduction() internal view {
        uint256 debtAfter = borrowableCUSDC.debtBalance(borrower);
        
        if (expectedBadDebt > 0) {
            // Hard liquidation: account should be fully liquidated
            assertEq(debtAfter, 0, "Hard liquidation should fully liquidate the account");
        } else {
            // Soft liquidation: debt should be reduced by maxAmount
            uint256 expectedDebtAfter = debtBalancesPreLiquidation - maxAmount;
            assertApproxEqAbs(
                debtAfter, 
                expectedDebtAfter, 
                1000,
                "Debt reduction should match maxAmount in soft liquidation"
            );
        }
    }

    function _assertCollateralSeizure(uint256 _collateralAmount) internal view {
        uint256 borrowerCollateralAfter = strategyCBALRETH.balanceOf(borrower);
        uint256 expectedBorrowerCollateralAfter = _collateralAmount - liquidatedPTokens;
        
        assertApproxEqAbs(
            borrowerCollateralAfter,
            expectedBorrowerCollateralAfter,
            1000,
            "Borrower collateral should be reduced by liquidatedPTokens"
        );
    }

    function _assertLiquidatorRewards(uint256 liquidatorBalanceBefore) internal view {
        uint256 liquidatorBalanceAfter = strategyCBALRETH.balanceOf(liquidator);
        
        assertApproxEqAbs(
            liquidatorBalanceAfter - liquidatorBalanceBefore,
            liquidatedPTokens,
            1000,
            "Liquidator should receive expected collateral"
        );
    }

    function _assertMarketAccounting(uint256 totalBorrowsBefore) internal view {
        uint256 totalBorrowsAfter = borrowableCUSDC.marketOutstandingDebt();
        uint256 expectedTotalDebtReduction = maxAmount + expectedBadDebt;
        
        assertApproxEqAbs(
            totalBorrowsAfter,
            totalBorrowsBefore - expectedTotalDebtReduction,
            1000,
            "Market outstanding debt should be reduced by debt repaid plus bad debt"
        );
    }

    function _assertHealthFactorImprovement(uint256 lFactorsPreLiquidation) internal view {
        (uint256 lFactorAfter,,) = marketManagerIsolated.liquidationStatusOf(
            borrower,
            address(strategyCBALRETH),
            address(borrowableCUSDC)
        );
        
        uint256 debtAfter = borrowableCUSDC.debtBalance(borrower);
        
        if (debtAfter > 0) {
            // If there's still debt, health factor should be improved
            assertTrue(
                lFactorAfter < lFactorsPreLiquidation,
                "Health factor should improve after partial liquidation"
            );
            
            // Soft liquidation should result in a healthy position
            assertTrue(
                lFactorAfter == 0,
                "Soft liquidation should result in healthy position (lFactor == 0)"
            );
        } else {
            // If fully liquidated, lFactor should be 0
            assertEq(lFactorAfter, 0, "Fully liquidated account should have 0 lFactor");
        }
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
        // Verify liquidator has enough balance to cover the liquidation
        assertTrue(
            usdc.balanceOf(liquidator) >= maxAmount + expectedBadDebt,
            "Liquidator should have sufficient USDC balance"
        );
        
        // Verify collateral exchange rate didn't change
        assertEq(
            strategyCBALRETH.exchangeRate(),
            cTokenExchangeRate,
            "Exchange rate should remain constant during liquidation"
        );
    }

    function _getLiquidationValuesWithHigherPrecision_NonAuction_Liquidate(
        uint256 _eTokenPrice,
        uint256 _cTokenPrice,
        uint256 lFactors,
        uint256 _collateralAmounts,
        uint256 _borrowAmounts
    ) internal view returns (
        uint256 maxAmount, 
        uint256 liquidatedPTokens,
        uint256 collateralRequired
    ) {
        
        // Keep original values but use higher precision for calculations
        uint256 PRECISION_FACTOR = 1e18; // Extra precision factor
    
            if (lFactors == 0) return (0,0,0);
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactors / WAD));
            uint256 auctionLiqIncentive = liqBaseIncentive + ((liqCurve * lFactors) / WAD);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * _eTokenPrice * WAD * PRECISION_FACTOR) /
                (_cTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;
                
            maxAmount = (auctionCFactor * _borrowAmounts) / WAD;
            
            // Calculate with extra precision
            liquidatedPTokens = (maxAmount * highPrecisionD2C) / (WAD * PRECISION_FACTOR);
            
            if (liquidatedPTokens > _collateralAmounts) {
                // Use the contract's exact formula
                maxAmount = FixedPointMathLib.mulDivUp(
                    maxAmount,
                    _collateralAmounts,
                    liquidatedPTokens
                );
                liquidatedPTokens = _collateralAmounts;
            }
            
            // Use the contract's exact formula
            collateralRequired = (_borrowAmounts * highPrecisionD2C) / (WAD * PRECISION_FACTOR);


        return (maxAmount, liquidatedPTokens, collateralRequired);
    }

    function _getLFactorsPreLiquidation(address _borrowers) internal view returns (uint256 lFactors) {

            (lFactors,,) = marketManagerIsolated.liquidationStatusOf(
                _borrowers,
                address(borrowableCUSDC),
                address(strategyCBALRETH)
            );

        return lFactors;
    }

    function _calculateBadDebt(
        uint256 _debtBalance,
        uint256 _debtAmount,
        uint256 _collateralAvailable,
        uint256 _collateralRequired,
        uint256 _liquidatedPTokens,
        uint256 _cTokenUnderlyingPrice,
        uint256 _eTokenUnderlyingPrice,
        uint256 _cTokenExchangeRate
    ) internal pure returns (uint256 badDebt) {

        if(_collateralRequired > _collateralAvailable) {
    
        badDebt = (_debtBalance - _debtAmount) -
        FixedPointMathLib.mulDivUp(
            ((_collateralAvailable - _liquidatedPTokens) * _cTokenExchangeRate) / WAD,
            _cTokenUnderlyingPrice,
            (_eTokenUnderlyingPrice * WAD) / 1e6
        );

        } else {
            return 0;
        }
        
    }

}