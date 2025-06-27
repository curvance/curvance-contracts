// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";

contract ETokenRepayTest is TestBaseEToken {
    event Repay(address payer, address borrower, uint256 repayAmount);

    function setUp() public override {
        super.setUp();

        _setCTokenConfigBasic(address(pBALRETH), 100_000e18, 0);

        _prepareUSDC(address(eUSDC), 2000e6);

        pBALRETH.postCollateral(1e18 - 1);

        _prepareUSDC(address(user1), 1000e6);

        vm.startPrank(user1);
        usdc.approve(address(eUSDC), type(uint256).max);
        eUSDC.mint(100e6, address(this));
        vm.stopPrank();

        eUSDC.borrow(100e6);

        skip(20 minutes);
    }

    function test_eTokenRepay_fail_whenRepayIsNotAllowed() public {
        rewind(1);

        vm.expectRevert();
        eUSDC.repay(100e6);
    }

    function test_eTokenRepay_fail_whenBorrowAmountExceedsCash() public {
        eUSDC.accrueIfNeeded();

        uint256 debtBalance = eUSDC.debtBalance(address(this));

        vm.expectRevert(BorrowableCToken.BorrowableCToken__InvalidParameter.selector);
        eUSDC.repay(debtBalance + 1);
    }

    function test_eTokenRepay_success() public {
        eUSDC.accrueIfNeeded();

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();
        uint256 totalBorrows = eUSDC.marketOutstandingDebt();

        vm.expectEmit(true, true, true, true, address(eUSDC)    );
        emit Repay(address(this), address(this), 100e6);

        eUSDC.repay(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
        assertEq(eUSDC.marketOutstandingDebt(), totalBorrows - 100e6);
    }

    function test_eTokenRepay_success_whenRepayAll() public {
        eUSDC.accrueIfNeeded();

        uint256 debtBalance = eUSDC.debtBalance(address(this));
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();
        uint256 totalBorrows = eUSDC.marketOutstandingDebt();
        uint256 expectedTotalBorrows;

        // If the totalBorrows adjustment won't be rounded down then we
        // pre-compute expected totalBorrows versus expecting a value
        // of 0.
        if (totalBorrows >= debtBalance) {
            expectedTotalBorrows = totalBorrows - debtBalance;
        }

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Repay(address(this), address(this), debtBalance);

        eUSDC.repay(0);
        
        assertEq(
            usdc.balanceOf(address(this)),
            underlyingBalance - debtBalance
        );
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
        assertEq(eUSDC.marketOutstandingDebt(), expectedTotalBorrows);
    }

    function test_borrowers_repayAllDebts() public {
        uint256 _BASE_UNDERLYING_RESERVE = 77777;
        uint256 initialUsdcReserves = 1000e6;
        _setCTokenConfigBasic(address(pBALRETH), 100_000e18, 0);

        uint256 addUsdcAmount = 1500e6;
        eUSDC.mint(
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
            deal(address(pBALRETH), user, 1e18);
            vm.startPrank(user);
            pBALRETH.postCollateral(1e18 - 1);
            eUSDC.borrow(100e6);
            vm.stopPrank();
        }

        // 2. repay user101 and user102 all debt after two days
        skip(2 days);
        for (uint i; i < 2; ++i) {
            address user = users[i];
            vm.startPrank(user);
            // give users enough usdc to repay their debt because accumulated interest
            _prepareUSDC(user, 1000e6);
            usdc.approve(address(eUSDC), type(uint256).max);
            eUSDC.repay(0);
            vm.stopPrank();
        }

        // can be called by malicious users
        for (uint i; i < 2; ++i) {
            skip(1 days);
            eUSDC.accrueIfNeeded();
        }

        _prepareUSDC(users[2], 1000e6);
        vm.startPrank(users[2]);
        usdc.approve(address(eUSDC), type(uint256).max);
        // 3. user103 repay all his debt would revert because overflow
        // vm.expectRevert();
        eUSDC.repay(0);
        vm.stopPrank();
    }
}
