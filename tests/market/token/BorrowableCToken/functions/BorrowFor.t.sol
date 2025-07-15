// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract BorrowableCTokenBorrowTest is TestBaseBorrowableCToken {
    event Borrow(uint256 borrowAmount, address borrower);

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
