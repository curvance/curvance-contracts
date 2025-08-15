// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

// 3 liquidations via auction with bad debt, 2 other users cannot be liquidated
// also harvest positions before liquidation

contract AuctionMultipleLiquidatedOthersNotTest is TestBaseLiquidations {
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

    function test_success_AuctionMultipleLiquidatedOthersNot() public {
        // Configure auction.
        _setAuctionConfigs(address(strategyCBALRETH), 11000, 3000);

        // Cache the expected liquidation values for all 3 liquidated borrowers.
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
        }));

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
        }));

        // Cache total debt.
        uint256 totalDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        // User1 debt and collateral before liquidation.
        uint256 user1DebtBefore = borrowableCUSDC.debtBalance(borrower1);
        uint256 user1CollateralBefore = strategyCBALRETH.collateralPosted(borrower1);

        // Cache debt and collateral for liquidated users only
        uint256 user2DebtBefore = borrowableCUSDC.debtBalance(borrower2);
        uint256 user2CollateralBefore = strategyCBALRETH.collateralPosted(borrower2);
        uint256 user3DebtBefore = borrowableCUSDC.debtBalance(borrower3);
        uint256 user3CollateralBefore = strategyCBALRETH.collateralPosted(borrower3);

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
        emit Repay(
            expectedLiquidationValuesBorrower1.debtRepaid + expectedLiquidationValuesBorrower1.badDebt, 
            address(this), 
            borrower1
        );
        
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Repay(
            expectedLiquidationValuesBorrower2.debtRepaid + expectedLiquidationValuesBorrower2.badDebt, 
            address(this), 
            borrower2
        );
        
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Repay(
            expectedLiquidationValuesBorrower3.debtRepaid + expectedLiquidationValuesBorrower3.badDebt, 
            address(this), 
            borrower3
        );
        
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(
            expectedLiquidationValuesBorrower1.badDebt + 
            expectedLiquidationValuesBorrower2.badDebt + 
            expectedLiquidationValuesBorrower3.badDebt, 
            address(this)
        );

        borrowableCUSDC.liquidate(usersToLiquidate, address(strategyCBALRETH));

        // Assert borrowers 1, 2, 3 were liquidated
        _assertMultipleLiquidations(
            expectedLiquidationValuesBorrower1,
            expectedLiquidationValuesBorrower2,
            expectedLiquidationValuesBorrower3,
            totalDebtBefore,
            user1DebtBefore,
            user1CollateralBefore,
            user2DebtBefore,
            user2CollateralBefore,
            user3DebtBefore,
            user3CollateralBefore,
            borrowableCUSDCBalanceBefore
        );

        // Get actual debt values for non liquidated borrowers to account for accrued interest
        uint256 actualBorrower4Debt = borrowableCUSDC.debtBalance(borrower4);
        uint256 actualBorrower5Debt = borrowableCUSDC.debtBalance(borrower5);
        
        _assertUserNotLiquidated(borrower4, actualBorrower4Debt, 1e18);
        _assertUserNotLiquidated(borrower5, actualBorrower5Debt, 1e18);
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
        // High LTV
        vm.startPrank(borrower1);
        borrowableCUSDC.borrow(1150e6, borrower1);
        vm.stopPrank();

        // High LTV
        vm.startPrank(borrower2);
        borrowableCUSDC.borrow(1140e6, borrower2);
        vm.stopPrank();

        // High LTV
        vm.startPrank(borrower3);
        borrowableCUSDC.borrow(1130e6, borrower3);
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

    function _assertMultipleLiquidations(
        ExpectedLiquidationValues memory expectedBorrower1,
        ExpectedLiquidationValues memory expectedBorrower2,
        ExpectedLiquidationValues memory expectedBorrower3,
        uint256 totalDebtBefore,
        uint256 user1DebtBefore,
        uint256 user1CollateralBefore,
        uint256 user2DebtBefore,
        uint256 user2CollateralBefore,
        uint256 user3DebtBefore,
        uint256 user3CollateralBefore,
        uint256 borrowableCUSDCBalanceBefore
    ) internal view {
        uint256 totalDebtReduction = 
            (expectedBorrower1.debtRepaid + expectedBorrower1.badDebt) +
            (expectedBorrower2.debtRepaid + expectedBorrower2.badDebt) +
            (expectedBorrower3.debtRepaid + expectedBorrower3.badDebt);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), 
            totalDebtBefore - totalDebtReduction);

        _assertLiquidatedUserDebtAndCollateral(borrower1, user1DebtBefore, user1CollateralBefore, expectedBorrower1);
        _assertLiquidatedUserDebtAndCollateral(borrower2, user2DebtBefore, user2CollateralBefore, expectedBorrower2);
        _assertLiquidatedUserDebtAndCollateral(borrower3, user3DebtBefore, user3CollateralBefore, expectedBorrower3);

        uint256 totalCollateralLiquidated = 
            expectedBorrower1.collateralLiquidated +
            expectedBorrower2.collateralLiquidated +
            expectedBorrower3.collateralLiquidated;
        assertEq(strategyCBALRETH.balanceOf(address(this)), totalCollateralLiquidated);

        uint256 totalDebtRepaid = 
            expectedBorrower1.debtRepaid +
            expectedBorrower2.debtRepaid +
            expectedBorrower3.debtRepaid;
        assertEq(usdc.balanceOf(address(borrowableCUSDC)), 
            borrowableCUSDCBalanceBefore + totalDebtRepaid);
    }

    function _assertLiquidatedUserDebtAndCollateral(
        address user,
        uint256 userDebtBefore,
        uint256 userCollateralBefore,
        ExpectedLiquidationValues memory expected
    ) internal view {
        uint256 expectedDebtReduction = expected.debtRepaid + expected.badDebt;
        assertEq(borrowableCUSDC.debtBalance(user), 
            userDebtBefore - expectedDebtReduction);

        assertEq(strategyCBALRETH.collateralPosted(user), 
            userCollateralBefore - expected.collateralLiquidated);
    }

    function _assertUserNotLiquidated(
        address user,
        uint256 expectedDebt,
        uint256 expectedCollateral
    ) internal view {
        assertEq(borrowableCUSDC.debtBalance(user), expectedDebt);
        assertEq(strategyCBALRETH.collateralPosted(user), expectedCollateral);
    }
}