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

        vm.expectRevert();
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

        skip(69 minutes);

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
            BorrowableCToken.BorrowableCToken__InvalidParameter.selector
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

        borrowableCUSDC.borrow(100e6, address(this));

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalBorrows + 100e6);
    }

    function test_borrowableCTokenBorrowFor_success() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        borrowableCUSDC.deposit(200e6, address(this));

        strategyCBALRETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalBorrows = borrowableCUSDC.marketOutstandingDebt();

        borrowableCUSDC.setDelegateApproval(user1, true);

        vm.prank(user1);
        borrowableCUSDC.borrowFor(100e6, address(this), address(this));

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalBorrows + 100e6);
    }
}
