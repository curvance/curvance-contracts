// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

// ## Scenario 2: Mixed Collateral Results w/ 92% LTV, all using liquidate() function
// - Setup: 4 users with different positions
// - User 1: 2.5 strategyCBALRETH ($4,000), 2,500 USDC debt (very healthy)
// - User 2: 2.0 strategyCBALRETH ($3,200), 2,500 USDC debt (healthy)
// - User 3: 1.9 strategyCBALRETH ($3,040), 2,500 USDC debt (borderline)
// - User 4: 1.7 strategyCBALRETH ($2,720), 2,500 USDC debt (risky)
// - Action: Price drop of strategyCBALRETH by 10% (to ~$1,420)
// - Expected: Users 3 and 4 liquidated, Users 1 and 2 remain healthy
//      User 3 has a soft liquidation, so no bad debt.
//      User 4 has a hard liquidation which accrues bad debt.

contract MixedCollateral is TestBaseLiquidations {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address borrower4 = makeAddr("borrower4");

    uint256 borrowAmount = 2500e6;
    address[] borrowers = [borrower1, borrower2, borrower3, borrower4];
    uint256[] collateralAmounts = [2.5e18, 2e18, 1.9e18, 1.7e18];

    event Repay(uint256 assets, address payer, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);

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
        _setCTokenConfigLowValues(address(borrowableCUSDC), 100_000e18, 100_000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _createPositions();

        mockWethFeed.setMockAnswer(1440e8);
        mockRethFeed.setMockAnswer(1440e8);

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

        (, uint256 collateralTokenPrice, uint256 debtTokenPrice, ) = 
            marketManagerIsolated.liquidationValuesOf(borrowers[0]);

        console2.log("debtTokenPrice", debtTokenPrice);
        console2.log("collateralTokenPrice", collateralTokenPrice);

        uint256 expectedTotalBadDebt;
        ExpectedLiquidationValues[] memory expectedLiqValues = new ExpectedLiquidationValues[](4);

        for(uint i; i < 4; i++) {

            expectedLiqValues[i] = _calculateExpectedLiquidationValues(
                LiquidationParams({
                    borrower: borrowers[i],
                    collateralToken: address(strategyCBALRETH),
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
            address(strategyCBALRETH)
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
            strategyCBALRETH.balanceOf(borrowers[3]),
            collateralAmounts[3] - expectedLiqValues[3].collateralLiquidated,
            1000, // Tolerance of 1000 wei 
            "Collateral post liquidation mismatch"
        );

        assertApproxEqAbs(
            strategyCBALRETH.balanceOf(borrowers[2]),
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
            strategyCBALRETH.balanceOf(address(this)),
            expectedLiquidatorBalance,
            1000,
            "Liquidator didn't receive expected collateral"
        );

        // Verify lFactors
        for(uint i = 2; i < 4; i++) {
            (, , , uint256 lFactorAfter) = marketManagerIsolated.liquidationValuesOf(borrowers[i]);

            console2.log("borrower", i, "lFactor", lFactorAfter);

            if(borrowableCUSDC.debtBalance(borrowers[i]) == 0) {
                assertTrue(lFactorAfter < lFactorsPreLiquidation[i], "Heath factor should be zero after full liquidation");
            }
        }
    }

    function _createPositions() internal {
        _prepareBALRETH(borrower1, collateralAmounts[0]);
        _prepareBALRETH(borrower2, collateralAmounts[1]);
        _prepareBALRETH(borrower3, collateralAmounts[2]);
        _prepareBALRETH(borrower4, collateralAmounts[3]);

        vm.startPrank(borrower1);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[0]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[0], borrower1);
        borrowableCUSDC.borrow(borrowAmount, borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[1]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[1], borrower2);
        borrowableCUSDC.borrow(borrowAmount, borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[2]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[2], borrower3);
        borrowableCUSDC.borrow(borrowAmount, borrower3);
        vm.stopPrank();

        vm.startPrank(borrower4);
        balRETH.approve(address(strategyCBALRETH), collateralAmounts[3]);
        strategyCBALRETH.depositAsCollateral(collateralAmounts[3], borrower4);
        borrowableCUSDC.borrow(borrowAmount, borrower4);
        vm.stopPrank();

    }

    function _getLFactorsPreLiquidation() internal view returns (uint256[] memory lFactors) {
        lFactors = new uint256[](4);

        for(uint i; i < 4; i++) {
            (, , , lFactors[i]) = marketManagerIsolated.liquidationValuesOf(borrowers[i]);
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