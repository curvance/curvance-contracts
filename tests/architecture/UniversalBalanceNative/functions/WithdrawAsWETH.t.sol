// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";

contract WithdrawAsWETHTest is TestBaseUniversalBalanceNative {
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function test_withdrawAsWETH_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        universalBalanceNative.depositETH{ value: amount }(true);

        vm.expectRevert();
        universalBalanceNative.withdrawAsWETH(amount + 1, true);

        vm.stopPrank();
    }

    function test_withdrawAsWETH_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        universalBalanceNative.depositETH{ value: amount }(false);

        vm.expectRevert();
        universalBalanceNative.withdrawAsWETH(amount + 1, false);

        vm.stopPrank();
    }

    function test_withdrawAsWETH_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalanceNative.UniversalBalance__InvalidParameter.selector
        );
        universalBalanceNative.withdrawAsWETH(0, false);
    }

    function test_withdrawAsWETH_success_withLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        deal(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalanceNative.depositETH{ value: depositAmount }(true);
        universalBalanceNative.depositETH{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 redeemAmount = eWETH.convertToShares(withdrawAmount);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalanceNative));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, withdrawAmount, redeemAmount);

        universalBalanceNative.withdrawAsWETH(withdrawAmount, true);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount);
        assertEq(lentBalance, depositAmount - withdrawAmount);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - redeemAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance + withdrawAmount);
    }

    function test_withdrawAsWETH_success_withoutLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        deal(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalanceNative.depositETH{ value: depositAmount }(true);
        universalBalanceNative.depositETH{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalanceNative));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, withdrawAmount, withdrawAmount);

        universalBalanceNative.withdrawAsWETH(withdrawAmount, false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount - withdrawAmount);
        assertEq(lentBalance, depositAmount);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - withdrawAmount
        );
        assertEq(eWETH.balanceOf(address(universalBalanceNative)), eWETHBalance);
        assertEq(weth.balanceOf(user1), userWETHBalance + withdrawAmount);
    }
}
