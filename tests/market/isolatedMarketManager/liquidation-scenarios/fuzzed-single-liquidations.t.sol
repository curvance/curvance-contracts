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
        borrowableCUSDC.borrow(_borrowAmount, borrower);
        vm.stopPrank();

        mockWethFeed.setMockAnswer(_oraclePrice);
        mockRethFeed.setMockAnswer(_oraclePrice);
        skip(20 minutes);

        (uint256 lFactorsPreLiquidation,,) = marketManagerIsolated.liquidationStatusOf(borrower, address(strategyCBALRETH), address(borrowableCUSDC));

        (uint256 lFactor, , ) = 
            marketManagerIsolated.liquidationStatusOf(borrower, address(strategyCBALRETH), address(borrowableCUSDC));
        
        _prepareUSDC(liquidator, 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000_000e6);

        if (lFactor == 0) {
            _handleNoLiquidationCase(_collateralAmount, _borrowAmount);
            return;
        }

        uint256 debtBalancePreLiquidation = borrowableCUSDC.debtBalanceUpdated(borrower);

        // Perform liquidation and run assertions
        _performLiquidationAndAssert(
            _collateralAmount, 
            lFactorsPreLiquidation,
            debtBalancePreLiquidation);
    }

    function _handleNoLiquidationCase(uint256 _collateralAmount, uint256 _debtBalancePreLiquidation) internal {
        vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));
        borrowableCUSDC.liquidate(borrowerArray, address(strategyCBALRETH));
        
        assertEq(borrowableCUSDC.debtBalance(borrower), _debtBalancePreLiquidation, "Debt should not change when lFactor is 0");
        assertEq(strategyCBALRETH.balanceOf(borrower), _collateralAmount, "Collateral should not change when lFactor is 0");
        assertEq(strategyCBALRETH.balanceOf(liquidator), 0, "Liquidator should not receive collateral when lFactor is 0");
    }

    function _performLiquidationAndAssert(
        uint256 _collateralAmount, 
        uint256 lFactorsPreLiquidation,
        uint256 _debtBalancePreLiquidation
    ) internal {
        // cache values before liquidation
        uint256 liquidatorBalanceBefore = strategyCBALRETH.balanceOf(liquidator);
        uint256 totalBorrowsBefore = borrowableCUSDC.marketOutstandingDebt();

        LiquidationParams memory params = LiquidationParams({
            borrower: borrower,
            collateralToken: address(strategyCBALRETH),
            borrowedToken: address(borrowableCUSDC),
            isLiquidateExact: false,
            liquidateExactAmount: 0,
            isAuction: false,
            isMultiMarketTest: false,
            marketManagerId: 0
        });

        ExpectedLiquidationValues memory expectedValues = 
        _calculateExpectedLiquidationValues(params);

        uint256 liquidatorUSDCBalanceBefore = usdc.balanceOf(liquidator);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(liquidator, expectedValues.badDebt);
        emit Repay(liquidator, borrower, expectedValues.debtRepaid);

        borrowableCUSDC.liquidate(borrowerArray, address(strategyCBALRETH));

        // Run all assertions
        _assertDebtReduction(
            expectedValues.badDebt,
            _debtBalancePreLiquidation,
            expectedValues.debtRepaid
        );
        _assertCollateralSeizure(_collateralAmount, expectedValues.collateralLiquidated);
        _assertLiquidatorRewards(liquidatorBalanceBefore, expectedValues.collateralLiquidated);
        _assertMarketAccounting(totalBorrowsBefore, expectedValues.debtRepaid);
        _assertHealthFactorImprovement(lFactorsPreLiquidation);
        _assertBadDebtHandling(
            expectedValues.badDebt,
            expectedValues.collateralRequired,
            _collateralAmount
        );
        _assertInvariants(
            liquidatorUSDCBalanceBefore,
            expectedValues.maxAmountRepaid
        );
    }

    function _assertDebtReduction(
        uint256 _expectedBadDebt,
        uint256 _debtBalancePreLiquidation,
        uint256 _debtRepaid
        ) internal view {
        uint256 debtAfter = borrowableCUSDC.debtBalance(borrower);
        
        if (_expectedBadDebt > 0) {
            // Hard liquidation: account should be fully liquidated
            assertEq(debtAfter, 0, "Hard liquidation should fully liquidate the account");
        } else {
            // Soft liquidation: debt should be reduced by maxAmount
            uint256 expectedDebtAfter = _debtBalancePreLiquidation - _debtRepaid;
            assertApproxEqAbs(
                debtAfter, 
                expectedDebtAfter, 
                1000,
                "Debt reduction should match maxAmount in soft liquidation"
            );
        }
    }

    function _assertCollateralSeizure(
        uint256 _collateralAmount,
        uint256 _collateralLiquidated
    ) internal view {
        uint256 borrowerCollateralAfter = strategyCBALRETH.balanceOf(borrower);
        uint256 expectedBorrowerCollateralAfter = _collateralAmount - _collateralLiquidated;
        
        assertApproxEqAbs(
            borrowerCollateralAfter,
            expectedBorrowerCollateralAfter,
            1000,
            "Borrower collateral should be reduced by collateralLiquidated"
        );
    }

    function _assertLiquidatorRewards(
        uint256 liquidatorBalanceBefore,
        uint256 _collateralLiquidated
    ) internal view {
        uint256 liquidatorBalanceAfter = strategyCBALRETH.balanceOf(liquidator);
        
        assertApproxEqAbs(
            liquidatorBalanceAfter - liquidatorBalanceBefore,
            _collateralLiquidated,
            1000,
            "Liquidator should receive expected collateral"
        );
    }

    function _assertMarketAccounting(
        uint256 _totalBorrowsBefore,
        uint256 _debtRepaid
        ) internal view {
        uint256 totalBorrowsAfter = borrowableCUSDC.marketOutstandingDebt();
        
        assertApproxEqAbs(
            totalBorrowsAfter,
            _totalBorrowsBefore - _debtRepaid,
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

    function _assertBadDebtHandling(
        uint256 _expectedBadDebt,
        uint256 _collateralRequired,
        uint256 _collateralAmount
    ) internal pure {
        if (_expectedBadDebt > 0) {
            assertTrue(
                _collateralRequired > _collateralAmount,
                "Bad debt should only occur when collateral is insufficient"
            );
        }
    }

    function _assertInvariants(
        uint256 liquidatorUSDCBalanceBefore,
        uint256 expectedMaxAmountRepaid
    ) internal view {
        // Verify liquidator has enough balance to cover the liquidation
        assertTrue(
            usdc.balanceOf(liquidator) == (liquidatorUSDCBalanceBefore - expectedMaxAmountRepaid),
            "Liquidator should have sufficient USDC balance"
        );
        
        // Verify collateral exchange rate didn't change
        assertEq(
            strategyCBALRETH.exchangeRate(),
            1e18,
            "Exchange rate should remain constant during liquidation"
        );
    }

}