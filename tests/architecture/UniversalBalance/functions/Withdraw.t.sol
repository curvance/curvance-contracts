// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract UniversalBalanceWithdrawTest is TestBaseUniversalBalance {
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        bool lendingRedemption
    );

    function test_universalBalanceWithdraw_fail_whenTransferIsDisabled()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.withdraw(1e6, false, address(this));

        vm.stopPrank();
    }

    function test_universalBalanceWithdraw_fail_whenCooldownIsNotEnded()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.withdraw(1e6, false, address(this));

        vm.stopPrank();
    }

    function test_universalBalanceWithdraw_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        vm.startPrank(user1);

        universalBalance.deposit(amount, true);

        vm.expectRevert();
        universalBalance.withdraw(amount + 1, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceWithdraw_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        vm.startPrank(user1);

        universalBalance.deposit(amount, false);

        vm.expectRevert();
        universalBalance.withdraw(amount + 1, false, user2);

        vm.stopPrank();
    }

    function test_universalBalanceWithdraw_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.withdraw(0, false, address(this));
    }

    function test_universalBalanceWithdraw_success_withLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        _prepareUSDC(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.deposit(depositAmount, true);
        universalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 redeemAmount = borrowableCUSDC.convertToShares(withdrawAmount);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 borrowableCUSDCBalance = borrowableCUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user2);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true, address(universalBalance));
        emit Withdraw(user1, user2, user1, withdrawAmount, true);

        universalBalance.withdraw(withdrawAmount, true, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount);
        assertEq(lentBalance, depositAmount - withdrawAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(
            borrowableCUSDC.balanceOf(address(universalBalance)),
            borrowableCUSDCBalance - redeemAmount
        );
        assertEq(usdc.balanceOf(user2), userUSDCBalance + withdrawAmount);
    }

    function test_universalBalanceWithdraw_success_withoutLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        _prepareUSDC(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.deposit(depositAmount, true);
        universalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 borrowableCUSDCBalance = borrowableCUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user2);

        vm.expectEmit(true, true, true, true, address(universalBalance));
        emit Withdraw(user1, user2, user1, withdrawAmount, false);

        vm.prank(user1);
        universalBalance.withdraw(withdrawAmount, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount - withdrawAmount);
        assertEq(lentBalance, depositAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance - withdrawAmount
        );
        assertEq(borrowableCUSDC.balanceOf(address(universalBalance)), borrowableCUSDCBalance);
        assertEq(usdc.balanceOf(user2), userUSDCBalance + withdrawAmount);
    }
}
