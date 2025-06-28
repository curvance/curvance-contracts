// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract ETokenBorrowTest is TestBaseEToken {
    event Borrow(address borrower, uint256 borrowAmount);

    function test_eTokenBorrow_fail_whenBorrowIsNotAllowed() public {
        marketManagerIsolated.setBorrowPaused(address(eUSDC), true);

        vm.expectRevert();
        eUSDC.borrow(100e6);
    }

    function test_eTokenBorrow_fail_whenBorrowAmountExceedsCash() public {
        uint256 cash = eUSDC.assetsHeld();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        eUSDC.borrow(cash + 1);
    }

    function test_eTokenBorrow_success() public {
        _setCTokenConfigBasic(address(pBALRETH), 100_000e18, 100_000e18);

        eUSDC.deposit(200e6, address(this));

        pBALRETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();
        uint256 totalBorrows = eUSDC.marketOutstandingDebt();

        eUSDC.borrow(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
        assertEq(eUSDC.marketOutstandingDebt(), totalBorrows + 100e6);
    }

    function test_eTokenBorrowFor_success() public {
        _setCTokenConfigBasic(address(pBALRETH), 100_000e18, 0);

        eUSDC.deposit(200e6, address(this));

        pBALRETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();
        uint256 totalBorrows = eUSDC.marketOutstandingDebt();

        eUSDC.setDelegateApproval(user1, true);

        vm.prank(user1);
        eUSDC.borrowFor(address(this), address(this), 100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
        assertEq(eUSDC.marketOutstandingDebt(), totalBorrows + 100e6);
    }
}
