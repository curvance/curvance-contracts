// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract UniversalBalanceShiftBalanceTest is TestBaseUniversalBalance {
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

    function test_universalBalanceShiftBalance_fail_whenTransferIsDisabled()
        public
    {
        _prepareUSDC(user1, 1e6);

        vm.startPrank(user1);

        universalBalance.deposit(1e6, false);

        centralRegistry.setTransferLockStatus(true);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.shiftBalance(1e6, false);

        vm.stopPrank();
    }

    function test_universalBalanceShiftBalance_fail_whenCooldownIsNotEnded()
        public
    {
        _prepareUSDC(user1, 1e6);

        vm.startPrank(user1);

        universalBalance.deposit(1e6, false);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.shiftBalance(1e6, false);

        vm.stopPrank();
    }

    function test_universalBalanceShiftBalance_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        vm.startPrank(user1);

        universalBalance.deposit(amount, true);

        vm.expectRevert();
        universalBalance.shiftBalance(amount + 1, true);

        vm.stopPrank();
    }

    function test_universalBalanceShiftBalance_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        vm.startPrank(user1);

        universalBalance.deposit(amount, false);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InsufficientBalance.selector
        );
        universalBalance.shiftBalance(amount + 1, false);

        vm.stopPrank();
    }

    function test_universalBalanceShiftBalance_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.shiftBalance(0, false);
    }

    function test_universalBalanceShiftBalance_success_fuzzed(
        uint256 depositAmount,
        uint256 shiftAmount,
        bool fromLent
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < shiftAmount && shiftAmount <= depositAmount);

        _prepareUSDC(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.deposit(depositAmount, true);
        universalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 redeemAmount = eUSDC.convertToShares(shiftAmount);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, shiftAmount, fromLent);
        vm.expectEmit();
        emit Deposit(user1, user1, shiftAmount, !fromLent);

        vm.prank(user1);
        universalBalance.shiftBalance(shiftAmount, fromLent);

        (
            uint256 userSittingBalance,
            uint256 userLentBalance
        ) = universalBalance.userBalances(user1);

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
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(usdc.balanceOf(user1), userUSDCBalance);

        if (fromLent) {
            usdcBalance += shiftAmount;
            eUSDCBalance -= redeemAmount;
        } else {
            usdcBalance -= shiftAmount;
            eUSDCBalance += redeemAmount;
        }

        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
    }
}
