// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract WithdrawTest is TestBaseUniversalBalance {
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function test_withdraw_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: amount }(true);

        vm.expectRevert();
        universalBalance.withdraw(amount + 1, true);

        vm.stopPrank();
    }

    function test_withdraw_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: amount }(false);

        vm.expectRevert();
        universalBalance.withdraw(amount + 1, false);

        vm.stopPrank();
    }

    function test_withdraw_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.withdraw(0, false);
    }

    function test_withdraw_success_withLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        deal(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: depositAmount }(true);
        universalBalance.depositETH{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 redeemAmount = eWETH.convertToShares(withdrawAmount);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, withdrawAmount, redeemAmount);

        universalBalance.withdraw(withdrawAmount, true);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount);
        assertEq(lentBalance, depositAmount - withdrawAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(address(universalBalance)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalance)),
            eWETHBalance - redeemAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance + withdrawAmount);
    }

    function test_withdraw_success_withoutLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        deal(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: depositAmount }(true);
        universalBalance.depositETH{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 ethBalance = address(universalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, withdrawAmount, withdrawAmount);

        universalBalance.withdraw(withdrawAmount, false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount - withdrawAmount);
        assertEq(lentBalance, depositAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalance)),
            wethBalance - withdrawAmount
        );
        assertEq(eWETH.balanceOf(address(universalBalance)), eWETHBalance);
        assertEq(weth.balanceOf(user1), userWETHBalance + withdrawAmount);
    }
}
