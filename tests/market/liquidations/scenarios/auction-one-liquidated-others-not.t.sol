// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

// 1 liquidation via auction with bad debt, 4 other users cannot be liquidated
// also harvest positions before liquidation

/// @dev NOTE: BORROWER 1 IS HARD LIQUIDATED, BUT ONLY ACCRUES BAD DEBT BECAUSE OF THE LIQUIDATION PENALTY WHICH PUSHES
///           IT FROM HARD LIQUIDATION TO BAD DEBT TERRITORY. BORROWERS 2-5 HAVE SAFE LTV AND CANNOT BE LIQUIDATED.

contract AuctionOneLiquidatedOthersNotTest is TestBaseLiquidations {
    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address borrower4 = makeAddr("borrower4");
    address borrower5 = makeAddr("borrower5");

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

    function test_success_AuctionOneLiquidatedOthersNot() public {
        // Configure auction.
        _setAuctionConfigs(address(strategyCBALRETH), 11000, 3000);

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

        // Cache total debt.
        uint256 totalDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        // User1 debt and collateral before liquidation.
        uint256 user1DebtBefore = borrowableCUSDC.debtBalance(borrower1);
        uint256 user1CollateralBefore = strategyCBALRETH.collateralPosted(borrower1);

        // Cache debt and collateral for users that should NOT be liquidated
        uint256 user2DebtBefore = borrowableCUSDC.debtBalance(borrower2);
        uint256 user2CollateralBefore = strategyCBALRETH.collateralPosted(borrower2);
        uint256 user3DebtBefore = borrowableCUSDC.debtBalance(borrower3);
        uint256 user3CollateralBefore = strategyCBALRETH.collateralPosted(borrower3);
        uint256 user4DebtBefore = borrowableCUSDC.debtBalance(borrower4);
        uint256 user4CollateralBefore = strategyCBALRETH.collateralPosted(borrower4);
        uint256 user5DebtBefore = borrowableCUSDC.debtBalance(borrower5);
        uint256 user5CollateralBefore = strategyCBALRETH.collateralPosted(borrower5);

        uint256 borrowableCUSDCBalanceBefore = usdc.balanceOf(address(borrowableCUSDC));

        _prepareUSDC(address(this), 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000_000e6);

        address[] memory usersToLiquidate = new address[](5);   
        usersToLiquidate[0] = borrower1;
        usersToLiquidate[1] = borrower2;
        usersToLiquidate[2] = borrower3;
        usersToLiquidate[3] = borrower4;
        usersToLiquidate[4] = borrower5;

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(
            expectedLiquidationValuesBorrower1.badDebt,
            address(this));
        emit Repay(expectedLiquidationValuesBorrower1.debtRepaid, address(this), borrower1);

        borrowableCUSDC.liquidate(usersToLiquidate, address(strategyCBALRETH));

        // Assert only borrower1 was liquidated
        _assertSingleLiquidation(
            expectedLiquidationValuesBorrower1,
            totalDebtBefore,
            user1DebtBefore,
            user1CollateralBefore,
            borrowableCUSDCBalanceBefore
        );

        // Assert other users were not liquidated
        _assertUserNotLiquidated(borrower2, user2DebtBefore, user2CollateralBefore);
        _assertUserNotLiquidated(borrower3, user3DebtBefore, user3CollateralBefore);
        _assertUserNotLiquidated(borrower4, user4DebtBefore, user4CollateralBefore);
        _assertUserNotLiquidated(borrower5, user5DebtBefore, user5CollateralBefore);
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
        _prepareBALRETH(borrower4, 1e18);
        _prepareBALRETH(borrower5, 1e18);

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

        vm.startPrank(borrower4);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18, borrower4);
        vm.stopPrank();

        vm.startPrank(borrower5);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18, borrower5);
        vm.stopPrank();
        
    }

    function _setUpBorrowerDebt() internal {
        // High ltv, trigger hard liquidation with bad debt
        vm.startPrank(borrower1);
        borrowableCUSDC.borrow(1150e6, borrower1);
        vm.stopPrank();

        // Safe LTV
        vm.startPrank(borrower2);
        borrowableCUSDC.borrow(500e6, borrower2);
        vm.stopPrank();

        // Safe LTV
        vm.startPrank(borrower3);
        borrowableCUSDC.borrow(400e6, borrower3);
        vm.stopPrank();

        // Safe LTV
        vm.startPrank(borrower4);
        borrowableCUSDC.borrow(300e6, borrower4);
        vm.stopPrank();

        // Safe LTV
        vm.startPrank(borrower5);
        borrowableCUSDC.borrow(200e6, borrower5);
        vm.stopPrank();
    }

    function _assertSingleLiquidation(
        ExpectedLiquidationValues memory expectedBorrower1,
        uint256 totalDebtBefore,
        uint256 user1DebtBefore,
        uint256 user1CollateralBefore,
        uint256 borrowableCUSDCBalanceBefore
    ) internal view {
        // Assert total market debt reduction (only borrower1)
        assertEq(borrowableCUSDC.marketOutstandingDebt(), 
            totalDebtBefore - (expectedBorrower1.debtRepaid + expectedBorrower1.badDebt)
        );

        // Assert borrower1 debt reduction (including bad debt)
        uint256 expectedDebtReduction = expectedBorrower1.debtRepaid + expectedBorrower1.badDebt;
        assertEq(borrowableCUSDC.debtBalance(borrower1), 
            user1DebtBefore - expectedDebtReduction);

        // Assert borrower1 collateral reduction
        assertEq(strategyCBALRETH.collateralPosted(borrower1), 
            user1CollateralBefore - expectedBorrower1.collateralLiquidated);

        // Assert liquidator received only borrower1's collateral
        assertEq(strategyCBALRETH.balanceOf(address(this)), 
            expectedBorrower1.collateralLiquidated);

        // Assert USDC transfer for only borrower1's debt repayment
        assertEq(usdc.balanceOf(address(borrowableCUSDC)), 
            borrowableCUSDCBalanceBefore + expectedBorrower1.debtRepaid);
    }

    function _assertUserNotLiquidated(
        address user,
        uint256 userDebtBefore,
        uint256 userCollateralBefore
    ) internal view {
        // Assert debt and collateral remain unchanged for non-liquidated users
        assertEq(borrowableCUSDC.debtBalance(user), userDebtBefore);
        assertEq(strategyCBALRETH.collateralPosted(user), userCollateralBefore);
    }
}