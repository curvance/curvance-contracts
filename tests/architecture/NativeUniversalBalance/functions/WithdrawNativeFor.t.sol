// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract WithdrawNativeForTest is TestBaseNativeUniversalBalance {
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        bool lendingRedemption
    );

    function setUp() public override {
        super.setUp();

        vm.prank(user1);
        nativeUniversalBalance.setDelegateApproval(user2, true);
    }

    function test_withdrawNativeFor_fail_whenRecipientIsNotApproved() public {
        deal(user1, _ONE);

        vm.startPrank(user1);

        nativeUniversalBalance.depositNative{ value: _ONE }(true);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        nativeUniversalBalance.withdrawNativeFor(
            _ONE,
            true,
            user2,
            address(1)
        );

        vm.stopPrank();
    }

    function test_withdrawNativeFor_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: amount }(true);

        vm.prank(user2);

        vm.expectRevert();
        nativeUniversalBalance.withdrawNativeFor(
            amount + 1,
            true,
            user2,
            user1
        );
    }

    function test_withdrawNativeFor_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: amount }(false);

        vm.prank(user2);

        vm.expectRevert();
        nativeUniversalBalance.withdrawNativeFor(
            amount + 1,
            false,
            user2,
            user1
        );
    }

    function test_withdrawNativeFor_fail_whenAmountIsZero() public {
        vm.prank(user2);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        nativeUniversalBalance.withdrawNativeFor(0, false, user2, user1);
    }

    function test_withdrawNativeFor_success_withLend_fuzzed(
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

        uint256 redeemAmount = borrowableCWETH.convertToShares(withdrawAmount);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user2.balance;

        vm.expectEmit(true, true, true, true, address(nativeUniversalBalance));
        emit Withdraw(user2, user2, user1, withdrawAmount, true);

        vm.prank(user2);
        nativeUniversalBalance.withdrawNativeFor(
            withdrawAmount,
            true,
            user2,
            user1
        );

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount);
        assertEq(lentBalance, depositAmount - withdrawAmount);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance - redeemAmount
        );
        assertEq(user2.balance, userETHBalance + withdrawAmount);
    }

    function test_withdrawNativeFor_success_withoutLend_fuzzed(
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
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user2.balance;

        vm.expectEmit(true, true, true, true, address(nativeUniversalBalance));
        emit Withdraw(user2, user2, user1, withdrawAmount, false);

        vm.prank(user2);
        nativeUniversalBalance.withdrawNativeFor(
            withdrawAmount,
            false,
            user2,
            user1
        );

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
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
        assertEq(user2.balance, userETHBalance + withdrawAmount);
    }
}
