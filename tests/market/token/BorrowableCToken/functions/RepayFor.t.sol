// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";

contract BorrowableCTokenRepayForTest is TestBaseBorrowableCToken {
    event Repay(address payer, address borrower, uint256 repayAmount);

    function setUp() public override {
        super.setUp();

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        _prepareUSDC(address(borrowableCUSDC), 2000e6);

        strategyCBALRETH.postCollateral(1e18 - 1);

        _prepareUSDC(address(user1), 1000e6);

        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.mint(100e6, address(this));
        vm.stopPrank();

        borrowableCUSDC.borrow(100e6, address(this));

        skip(20 minutes);
    }


    function test_borrowableCTokenRepayFor_success() public {

       borrowableCUSDC.accrueIfNeeded();

       uint256 currentDebt = borrowableCUSDC.debtBalance(address(this));

       uint256 underlyingBalance = usdc.balanceOf(address(borrowableCUSDC));

        _prepareUSDC(user2, currentDebt);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), currentDebt);
        
        borrowableCUSDC.repayFor(currentDebt, address(this));

        uint256 newDebt = borrowableCUSDC.debtBalance(address(this));
        
        assertEq(newDebt, 0);
        assertEq(usdc.balanceOf(user2), 0);
        assertEq(usdc.balanceOf(address(borrowableCUSDC)), underlyingBalance + currentDebt);

    }

}
