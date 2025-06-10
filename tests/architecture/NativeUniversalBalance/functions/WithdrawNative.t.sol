// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";

contract WithdrawNativeTest is TestBaseNativeUniversalBalance {
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        bool lendingRedemption
    );

    function test_withdrawNative_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        nativeUniversalBalance.depositNative{ value: amount }(true);

        vm.expectRevert();
        nativeUniversalBalance.withdrawNative(amount + 1, true, user2);

        vm.stopPrank();
    }

    function test_withdrawNative_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        nativeUniversalBalance.depositNative{ value: amount }(false);

        vm.expectRevert();
        nativeUniversalBalance.withdrawNative(amount + 1, false, user2);

        vm.stopPrank();
    }

    function test_withdrawNative_fail_whenAmountIsZero() public {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        nativeUniversalBalance.withdrawNative(0, false, user2);
    }

    function test_withdrawNative_success_withLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        deal(user1, depositAmount * 2);

        vm.startPrank(user1);

        nativeUniversalBalance.depositNative{ value: depositAmount }(true);
        nativeUniversalBalance.depositNative{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 redeemAmount = eWETH.convertToShares(withdrawAmount);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user2.balance;

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user2, user1, withdrawAmount, true);

        nativeUniversalBalance.withdrawNative(withdrawAmount, true, user2);

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount);
        assertEq(lentBalance, depositAmount - withdrawAmount);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(nativeUniversalBalance)),
            eWETHBalance - redeemAmount
        );
        assertEq(user2.balance, userETHBalance + withdrawAmount);
    }

    function test_withdrawNative_success_withoutLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        deal(user1, depositAmount * 2);

        vm.startPrank(user1);

        nativeUniversalBalance.depositNative{ value: depositAmount }(true);
        nativeUniversalBalance.depositNative{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user2.balance;

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user2, user1, withdrawAmount, false);

        nativeUniversalBalance.withdrawNative(withdrawAmount, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount - withdrawAmount);
        assertEq(lentBalance, depositAmount);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance - withdrawAmount
        );
        assertEq(
            eWETH.balanceOf(address(nativeUniversalBalance)),
            eWETHBalance
        );
        assertEq(user2.balance, userETHBalance + withdrawAmount);
    }
}
