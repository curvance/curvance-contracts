// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract BorrowableCTokenBorrowTest is TestBaseBorrowableCToken {
    event Borrow(uint256 borrowAmount, address borrower);

    function test_borrowableCTokenBorrow_fail_whenBorrowIsNotAllowed() public {
        address borrower = makeAddr("borrower");
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.borrow(100e6, borrower);
    }

    function test_borrowableCTokenBorrow_fail_whenBorrowAmountExceedsAssetsHeld() public {
        address liquidityProvider = makeAddr("liquidityProvider");

        _prepareUSDC(liquidityProvider, 100e6);
        // Mint borrowableCUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);
        vm.stopPrank();


        _prepareBALRETH(address(this), _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, address(this));
        strategyCBALRETH.postCollateral(_ONE);

        _harvestAuraStrategyRewards(1 weeks);

        uint256 assetsHeld = borrowableCUSDC.assetsHeld();

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__InsufficientAssetsHeld.selector
        );
        borrowableCUSDC.borrow(assetsHeld + 1, address(this));
    }

    function test_borrowableCTokenBorrow_fail_whenBorrowAmountExceedsDebtCap() public {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 100e6);
        // mint borrowableCUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);
        vm.stopPrank();

        _prepareBALRETH(address(this), _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, address(this));
        strategyCBALRETH.postCollateral(_ONE);

        skip(69 minutes);
        _harvestAuraStrategyRewards(1 weeks);

        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        borrowableCUSDC.borrow(100e6, address(this));
    }

    function test_borrowableCTokenBorrow_fail_whenCollateralPostedInBorrowableCToken() public {

        borrowableCUSDC.deposit(200e6, address(this));

        strategyCBALRETH.postCollateral(1e18 - 1);
        borrowableCUSDC.postCollateral(100e6 - 1);

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__CollateralPositionActive.selector
        );

        borrowableCUSDC.borrow(20e6, address(this));
    }

    function test_borrowableCTokenBorrow_success() public {
        borrowableCUSDC.deposit(200e6, address(this));
        strategyCBALRETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalBorrows = borrowableCUSDC.marketOutstandingDebt();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Borrow(100e6, address(this));

        borrowableCUSDC.borrow(100e6, address(this));

        // Initial assertions
        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalBorrows + 100e6);

        // Test interest accrual over time
        _harvestAuraStrategyRewards(1 weeks);

        uint256 debtBeforeAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsBeforeAccrual = borrowableCUSDC.totalAssets();

        borrowableCUSDC.accrueIfNeeded();

        uint256 debtAfterAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsAfterAccrual = borrowableCUSDC.totalAssets();

        assertGt(debtAfterAccrual, 100e6, "Debt should include accrued interest");
        assertGt(debtAfterAccrual, debtBeforeAccrual, "Debt should increase after accrual");

        uint256 debtIncrease = debtAfterAccrual - debtBeforeAccrual;
        uint256 assetsIncrease = totalAssetsAfterAccrual - totalAssetsBeforeAccrual;
        assertEq(debtIncrease, assetsIncrease, "Debt increase must equal assets increase");
    }


}
