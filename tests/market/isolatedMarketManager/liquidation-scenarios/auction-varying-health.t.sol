// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

// 3 liquidations, all are auctions, 2 are soft liquidated, 1 is hard liquidated
// also harvest positions before liquidation

contract AuctionVaryingHealthTest is TestBaseMarketManagerIsolated {
    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");

    event Repay(uint256 assets, address payer, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);

    function setUp() public override {
        super.setUp();

        // Set up positions.
        _setUpMarketPreLiquidation();
        _setUpBorrowerCollateral();
        _setUpBorrowerDebt();
        _harvestAuraStrategyRewards(2 weeks);

        // set mock prices
        mockWethFeed.setMockAnswer(1185e8);
        mockRethFeed.setMockAnswer(1185e8);

        // accrue interest
        borrowableCUSDC.accrueIfNeeded();
        strategyCBALRETH.accrueIfNeeded();
    }

    function testMultipleLiquidationsWithOnlyAuctions() public {
        // Set auction parameters.
        _setAuctionParams(
            1.10e18, //10%
            0.30e18  // 30%
        );

        // Cache the expected liquidation values.
        ExpectedLiquidationValues memory expectedLiquidationValuesBorrower1 = _calculateExpectedLiquidationValues(
            LiquidationParams({
            borrower: borrower1,
            collateralToken: address(strategyCBALRETH),
            borrowedToken: address(borrowableCUSDC),
            isLiquidateExact: false,
            liquidateExactAmount: 0,
            isAuction: true,
            isMultiMarketTest: false,
            marketManagerId: 0
        }));

        ExpectedLiquidationValues memory expectedLiquidationValuesBorrower2 = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: borrower2,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: true,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        ExpectedLiquidationValues memory expectedLiquidationValuesBorrower3 = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: borrower3,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: true,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // Cache total debt.
        uint256 totalDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        // User1 debt and collateral before liquidation.
        uint256 user1DebtBefore = borrowableCUSDC.debtBalance(borrower1);
        uint256 user1CollateralBefore = strategyCBALRETH.collateralPosted(borrower1);

        // User2 debt and collateral before liquidation.
        uint256 user2DebtBefore = borrowableCUSDC.debtBalance(borrower2);
        uint256 user2CollateralBefore = strategyCBALRETH.collateralPosted(borrower2);

        // User3 debt and collateral before liquidation.
        uint256 user3DebtBefore = borrowableCUSDC.debtBalance(borrower3);
        uint256 user3CollateralBefore = strategyCBALRETH.collateralPosted(borrower3);

        _prepareUSDC(address(this), 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000_000e6);

        address[] memory usersToLiquidate = new address[](3);   
        usersToLiquidate[0] = borrower1;
        usersToLiquidate[1] = borrower2;
        usersToLiquidate[2] = borrower3;

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(
            expectedLiquidationValuesBorrower1.badDebt,
            address(this));
        emit Repay(expectedLiquidationValuesBorrower1.debtRepaid, address(this), borrower1);
        emit Repay(expectedLiquidationValuesBorrower2.debtRepaid, address(this), borrower2);
        emit Repay(expectedLiquidationValuesBorrower3.debtRepaid, address(this), borrower3);

        borrowableCUSDC.liquidate(usersToLiquidate, address(strategyCBALRETH));

        // Use helper functions to reduce stack depth.
        _assertDebtReductions(
            expectedLiquidationValuesBorrower1,
            expectedLiquidationValuesBorrower2, 
            expectedLiquidationValuesBorrower3,
            totalDebtBefore
        );

        _assertUserDebtAndCollateralChanges(borrower1, user1DebtBefore, user1CollateralBefore, expectedLiquidationValuesBorrower1);
        _assertUserDebtAndCollateralChanges(borrower2, user2DebtBefore, user2CollateralBefore, expectedLiquidationValuesBorrower2);  
        _assertUserDebtAndCollateralChanges(borrower3, user3DebtBefore, user3CollateralBefore, expectedLiquidationValuesBorrower3);

        _assertLiquidatorCollateralSeizure(
            expectedLiquidationValuesBorrower1,
            expectedLiquidationValuesBorrower2,
            expectedLiquidationValuesBorrower3
        );

        _assertUSDCTransfer(
            borrowableCUSDCBalanceBefore,
            expectedLiquidationValuesBorrower1,
            expectedLiquidationValuesBorrower2,
            expectedLiquidationValuesBorrower3
        );
    }

    function _setUpMarketPreLiquidation() internal {
        // Setup market with tokens.
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777 + 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 77777 + 1_000_000e6);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // provide liquidity to the market
        borrowableCUSDC.deposit(1_000_000e6, address(this));
    }

    function _setUpBorrowerCollateral() internal {
        _prepareBALRETH(borrower1, 1e18);
        _prepareBALRETH(borrower2, 1e18);
        _prepareBALRETH(borrower3, 1e18);

        // Deposit collateral.
        
        vm.startPrank(borrower1);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18, borrower1);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18, borrower2);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18, borrower3);
        vm.stopPrank();
    }

    function _setUpBorrowerDebt() internal {
        // High ltv, trigger hard liquidation.
        vm.startPrank(borrower1);
        borrowableCUSDC.borrow(1150e6, borrower1);
        vm.stopPrank();

        // Medium ltv, trigger soft liquidation.
        vm.startPrank(borrower2);
        borrowableCUSDC.borrow(900e6, borrower2);
        vm.stopPrank();

        // Slightly lower than medium ltv, trigger soft liquidation.
        vm.startPrank(borrower3);
        borrowableCUSDC.borrow(880e6, borrower3);
        vm.stopPrank();
    }

    function _assertDebtReductions(
        ExpectedLiquidationValues memory expectedBorrower1,
        ExpectedLiquidationValues memory expectedBorrower2, 
        ExpectedLiquidationValues memory expectedBorrower3,
        uint256 totalDebtBefore
    ) internal {
        // Assert total market debt reduction.
        assertEq(borrowableCUSDC.marketOutstandingDebt(), 
            totalDebtBefore - 
            (expectedBorrower1.debtRepaid + expectedBorrower1.badDebt +
            expectedBorrower2.debtRepaid + 
            expectedBorrower3.debtRepaid)
        );
    }

    function _assertUserDebtAndCollateralChanges(
        address user,
        uint256 userDebtBefore,
        uint256 userCollateralBefore,
        ExpectedLiquidationValues memory expected
    ) internal {
        // Assert user debt reduction (including bad debt for underwater positions).
        uint256 expectedDebtReduction = expected.debtRepaid + expected.badDebt;
        assertEq(borrowableCUSDC.debtBalance(user), 
            userDebtBefore - expectedDebtReduction);

        // Assert user collateral reduction.
        assertEq(strategyCBALRETH.collateralPosted(user), 
            userCollateralBefore - expected.collateralLiquidated);
    }

    function _assertLiquidatorCollateralSeizure(
        ExpectedLiquidationValues memory expectedBorrower1,
        ExpectedLiquidationValues memory expectedBorrower2,
        ExpectedLiquidationValues memory expectedBorrower3
    ) internal {
        assertEq(strategyCBALRETH.balanceOf(address(this)), 
            (expectedBorrower1.collateralLiquidated + 
            expectedBorrower2.collateralLiquidated + 
            expectedBorrower3.collateralLiquidated)
        );
    }

    function _assertUSDCTransfer(
        uint256 borrowableCUSDCBalanceBefore,
        ExpectedLiquidationValues memory expectedBorrower1,
        ExpectedLiquidationValues memory expectedBorrower2,
        ExpectedLiquidationValues memory expectedBorrower3
    ) internal {
        assertEq(usdc.balanceOf(address(borrowableCUSDC)), 
        borrowableCUSDCBalanceBefore + 
        expectedBorrower1.debtRepaid + 
        expectedBorrower2.debtRepaid + 
        expectedBorrower3.debtRepaid);
    }
}