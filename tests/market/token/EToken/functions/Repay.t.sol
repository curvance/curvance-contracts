// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { EToken } from "contracts/market/token/EToken.sol";

contract ETokenRepayTest is TestBaseEToken {
    event Repay(address payer, address borrower, uint256 repayAmount);

    function setUp() public override {
        super.setUp();

        _setPBALRETHCollateralCaps(100_000e18);

        _prepareUSDC(address(eUSDC), 2000e6);

        marketManager.postCollateral(
            address(this),
            address(pBALRETH),
            1e18 - 1
        );

        vm.prank(user1);
        eUSDC.mintFor(100e6, address(this));

        eUSDC.borrow(100e6);

        skip(20 minutes);
    }

    function test_eTokenRepay_fail_whenRepayIsNotAllowed() public {
        rewind(1);

        vm.expectRevert();
        eUSDC.repay(100e6);
    }

    function test_eTokenRepay_fail_whenBorrowAmountExceedsCash() public {
        eUSDC.accrueInterest();

        uint256 debtBalanceCached = eUSDC.debtBalanceCached(address(this));

        vm.expectRevert(EToken.EToken__ExcessiveValue.selector);
        eUSDC.repay(debtBalanceCached + 1);
    }

    function test_eTokenRepay_success() public {
        eUSDC.accrueInterest();

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();
        uint256 totalBorrows = eUSDC.totalBorrows();

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Repay(address(this), address(this), 100e6);

        eUSDC.repay(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
        assertEq(eUSDC.totalBorrows(), totalBorrows - 100e6);
    }

    function test_eTokenRepay_success_whenRepayAll() public {
        eUSDC.accrueInterest();

        uint256 debtBalanceCached = eUSDC.debtBalanceCached(address(this));
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();
        uint256 totalBorrows = eUSDC.totalBorrows();
        uint256 expectedTotalBorrows;

        // If the totalBorrows adjustment won't be rounded down then we
        // pre-compute expected totalBorrows versus expecting a value
        // of 0.
        if (totalBorrows >= debtBalanceCached) {
            expectedTotalBorrows = totalBorrows - debtBalanceCached;
        }

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Repay(address(this), address(this), debtBalanceCached);

        eUSDC.repay(0);
        
        assertEq(
            usdc.balanceOf(address(this)),
            underlyingBalance - debtBalanceCached
        );
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
        assertEq(eUSDC.totalBorrows(), expectedTotalBorrows);
    }

    function test_borrowers_repayAllDebts() public {
        uint256 _BASE_UNDERLYING_RESERVE = 42069;
        uint256 initialUsdcReserves = 1000e6;
        _setPBALRETHCollateralCaps(100_000e18);

        uint256 addUsdcAmount = 1500e6;
        eUSDC.mint(
            _BASE_UNDERLYING_RESERVE + initialUsdcReserves + addUsdcAmount
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
            marketManager.postCollateral(user, address(pBALRETH), 1e18 - 1);
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
            eUSDC.accrueInterest();
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
