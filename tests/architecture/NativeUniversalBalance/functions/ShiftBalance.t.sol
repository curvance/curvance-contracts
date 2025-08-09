// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract NativeUniversalBalanceShiftBalanceTest is
    TestBaseNativeUniversalBalance
{
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        bool lendingRedemption
    );

    function test_nativeUniversalBalanceShiftBalance_fail_whenTransferIsDisabled()
        public
    {
        _prepareWETH(user1, 1e6);

        vm.startPrank(user1);

        nativeUniversalBalance.deposit(1e6, false);

        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        nativeUniversalBalance.shiftBalance(1e6, false);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceShiftBalance_fail_whenCooldownIsNotEnded()
        public
    {
        _prepareWETH(user1, 1e6);

        vm.startPrank(user1);

        nativeUniversalBalance.deposit(1e6, false);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        nativeUniversalBalance.shiftBalance(1e6, false);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceShiftBalance_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        nativeUniversalBalance.deposit(amount, true);

        vm.expectRevert();
        nativeUniversalBalance.shiftBalance(amount + 1, true);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceShiftBalance_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        nativeUniversalBalance.deposit(amount, false);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InsufficientBalance.selector
        );
        nativeUniversalBalance.shiftBalance(amount + 1, false);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceShiftBalance_fail_whenAmountIsZero()
        public
    {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        nativeUniversalBalance.shiftBalance(0, false);
    }

    function test_nativeUniversalBalanceShiftBalance_success_fuzzed(
        uint256 depositAmount,
        uint256 shiftAmount,
        bool fromLent
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < shiftAmount && shiftAmount <= depositAmount);

        _prepareWETH(user1, depositAmount * 2);

        vm.startPrank(user1);

        nativeUniversalBalance.deposit(depositAmount, true);
        nativeUniversalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 redeemAmount = borrowableCWETH.convertToShares(shiftAmount);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userUSDCBalance = weth.balanceOf(user1);

        vm.expectEmit(true, true, false, true, address(nativeUniversalBalance));
        emit Withdraw(user1, user1, user1, shiftAmount, fromLent);
        vm.expectEmit(true, true, false, true, address(nativeUniversalBalance));
        emit Deposit(user1, user1, shiftAmount, !fromLent);

        vm.prank(user1);
        nativeUniversalBalance.shiftBalance(shiftAmount, fromLent);

        (
            uint256 userSittingBalance,
            uint256 userLentBalance
        ) = nativeUniversalBalance.userBalances(user1);

        assertEq(
            userSittingBalance,
            fromLent
                ? depositAmount + shiftAmount
                : depositAmount - shiftAmount
        );
        assertEq(
            userLentBalance,
            fromLent
                ? depositAmount - shiftAmount
                : depositAmount + shiftAmount
        );
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(user1), userUSDCBalance);

        if (fromLent) {
            wethBalance += shiftAmount;
            borrowableCWETHBalance -= redeemAmount;
        } else {
            wethBalance -= shiftAmount;
            borrowableCWETHBalance += redeemAmount;
        }

        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
    }
}
