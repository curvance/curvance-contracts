// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";

contract BorrowableCTokenRepayTest is TestBaseBorrowableCToken {
    event Repay(uint256 repayAmount, address payer, address borrower);

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

        borrowableCUSDC.borrow(100e6, user1);

        skip(20 minutes);
    }

    function test_borrowableCTokenRepay_fail_whenRepayIsNotAllowed() public {
        rewind(1);

        vm.expectRevert();
        borrowableCUSDC.repay(100e6);
    }

    function test_borrowableCTokenRepay_fail_whenBorrowAmountExceedsCash() public {
        borrowableCUSDC.accrueIfNeeded();

        uint256 debtBalance = borrowableCUSDC.debtBalance(address(this));

        vm.expectRevert(BorrowableCToken.BorrowableCToken__InvalidParameter.selector);
        borrowableCUSDC.repay(debtBalance + 1);
    }

    function test_borrowableCTokenRepay_success() public {
        borrowableCUSDC.accrueIfNeeded();

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalBorrows = borrowableCUSDC.marketOutstandingDebt();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC)    );
        emit Repay(100e6, address(this), address(this));

        borrowableCUSDC.repay(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalBorrows - 100e6);
    }

    function test_borrowableCTokenRepay_success_whenRepayAll() public {
        borrowableCUSDC.accrueIfNeeded();

        uint256 debtBalance = borrowableCUSDC.debtBalance(address(this));
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalBorrows = borrowableCUSDC.marketOutstandingDebt();
        uint256 expectedTotalBorrows;

        // If the totalBorrows adjustment won't be rounded down then we
        // pre-compute expected totalBorrows versus expecting a value
        // of 0.
        if (totalBorrows >= debtBalance) {
            expectedTotalBorrows = totalBorrows - debtBalance;
        }

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Repay(debtBalance, address(this), address(this));

        borrowableCUSDC.repay(0);
        
        assertEq(
            usdc.balanceOf(address(this)),
            underlyingBalance - debtBalance
        );
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), expectedTotalBorrows);
    }

    function test_borrowers_repayAllDebts() public {
        uint256 _BASE_UNDERLYING_RESERVE = 77777;
        uint256 initialUsdcReserves = 1000e6;
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        uint256 addUsdcAmount = 1500e6;
        borrowableCUSDC.mint(
            _BASE_UNDERLYING_RESERVE + initialUsdcReserves + addUsdcAmount,
            address(this)
        );

        address user101 = address(101);
        address user102 = address(102);
        address user103 = address(103);
        address[] memory users = new address[](3);
        users[0] = user101;
        users[1] = user102;
        users[2] = user103;

        // 1. users post collateral and borrow 100 usdc
        for (uint i; i < 3; ++i) {
            address user = users[i];
            deal(address(strategyCBALRETH), user, 1e18);
            vm.startPrank(user);
            strategyCBALRETH.postCollateral(1e18 - 1);
            borrowableCUSDC.borrow(100e6, user);
            vm.stopPrank();
        }

        // 2. repay user101 and user102 all debt after two days
        skip(2 days);
        for (uint i; i < 2; ++i) {
            address user = users[i];
            vm.startPrank(user);
            // give users enough usdc to repay their debt because accumulated interest
            _prepareUSDC(user, 1000e6);
            usdc.approve(address(borrowableCUSDC), type(uint256).max);
            borrowableCUSDC.repay(0);
            vm.stopPrank();
        }

        // can be called by malicious users
        for (uint i; i < 2; ++i) {
            skip(1 days);
            borrowableCUSDC.accrueIfNeeded();
        }

        _prepareUSDC(users[2], 1000e6);
        vm.startPrank(users[2]);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        // 3. user103 repay all his debt would revert because overflow
        // vm.expectRevert();
        borrowableCUSDC.repay(0);
        vm.stopPrank();
    }
}
