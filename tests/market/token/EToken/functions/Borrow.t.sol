// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract ETokenBorrowTest is TestBaseEToken {
    event Borrow(address borrower, uint256 borrowAmount);

    function test_eTokenBorrow_fail_whenBorrowIsNotAllowed() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.expectRevert();
        borrowableCUSDC.borrow(100e6);
    }

    function test_eTokenBorrow_fail_whenBorrowAmountExceedsCash() public {
        uint256 cash = borrowableCUSDC.assetsHeld();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        borrowableCUSDC.borrow(cash + 1);
    }

    function test_eTokenBorrow_success() public {
        _setCTokenConfigBasic(address(pBALRETH), 100_000e18, 100_000e18);

        borrowableCUSDC.deposit(200e6, address(this));

        pBALRETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalBorrows = borrowableCUSDC.marketOutstandingDebt();

        borrowableCUSDC.borrow(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalBorrows + 100e6);
    }

    function test_eTokenBorrowFor_success() public {
        _setCTokenConfigBasic(address(pBALRETH), 100_000e18, 0);

        borrowableCUSDC.deposit(200e6, address(this));

        pBALRETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalBorrows = borrowableCUSDC.marketOutstandingDebt();

        borrowableCUSDC.setDelegateApproval(user1, true);

        vm.prank(user1);
        borrowableCUSDC.borrowFor(address(this), address(this), 100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalBorrows + 100e6);
    }
}
