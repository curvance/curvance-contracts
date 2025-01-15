// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract ETokenBorrowTest is TestBaseEToken {
    event Borrow(address borrower, uint256 borrowAmount);

    function test_eTokenBorrow_fail_whenBorrowIsNotAllowed() public {
        marketManager.setBorrowPaused(address(eUSDC), true);

        vm.expectRevert();
        eUSDC.borrow(100e6);
    }

    function test_eTokenBorrow_fail_whenBorrowAmountExceedsCash() public {
        uint256 cash = eUSDC.marketUnderlyingHeld();

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        eUSDC.borrow(cash + 1);
    }

    function test_eTokenBorrow_success() public {
        _setPBALRETHCollateralCaps(100_000e18);

        eUSDC.mint(200e6);

        marketManager.postCollateral(
            address(this),
            address(pBALRETH),
            1e18 - 1
        );

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();
        uint256 totalBorrows = eUSDC.totalBorrows();

        eUSDC.borrow(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
        assertEq(eUSDC.totalBorrows(), totalBorrows + 100e6);
    }

    function test_eTokenBorrowFor_success() public {
        _setPBALRETHCollateralCaps(100_000e18);

        eUSDC.mint(200e6);

        marketManager.postCollateral(
            address(this),
            address(pBALRETH),
            1e18 - 1
        );

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();
        uint256 totalBorrows = eUSDC.totalBorrows();

        eUSDC.setDelegateApproval(user1, true);

        vm.prank(user1);
        eUSDC.borrowFor(address(this), address(this), 100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
        assertEq(eUSDC.totalBorrows(), totalBorrows + 100e6);
    }
}
