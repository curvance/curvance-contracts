// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";

contract WithdrawNativeForTest is TestBaseUniversalBalanceNative {
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public override {
        super.setUp();

        vm.prank(user1);
        universalBalanceNative.setDelegateApproval(user2, true);
    }

    function test_withdrawNativeFor_fail_whenRecipientIsNotApproved() public {
        deal(user1, _ONE);

        vm.startPrank(user1);

        universalBalanceNative.depositNative{ value: _ONE }(true);

        vm.expectRevert();
        universalBalanceNative.withdrawNativeFor(
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
        universalBalanceNative.depositNative{ value: amount }(true);

        vm.prank(user2);

        vm.expectRevert();
        universalBalanceNative.withdrawNativeFor(
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
        universalBalanceNative.depositNative{ value: amount }(false);

        vm.prank(user2);

        vm.expectRevert();
        universalBalanceNative.withdrawNativeFor(
            amount + 1,
            false,
            user2,
            user1
        );
    }

    function test_withdrawNativeFor_fail_whenAmountIsZero() public {
        vm.prank(user2);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        universalBalanceNative.withdrawNativeFor(0, false, user2, user1);
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

        universalBalanceNative.depositNative{ value: depositAmount }(true);
        universalBalanceNative.depositNative{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 redeemAmount = eWETH.convertToShares(withdrawAmount);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user2.balance;

        vm.expectEmit();
        emit Withdraw(user2, user2, user1, withdrawAmount, redeemAmount);

        vm.prank(user2);
        universalBalanceNative.withdrawNativeFor(
            withdrawAmount,
            true,
            user2,
            user1
        );

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

        universalBalanceNative.depositNative{ value: depositAmount }(true);
        universalBalanceNative.depositNative{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user2.balance;

        vm.expectEmit();
        emit Withdraw(user2, user2, user1, withdrawAmount, withdrawAmount);

        vm.prank(user2);
        universalBalanceNative.withdrawNativeFor(
            withdrawAmount,
            false,
            user2,
            user1
        );

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount - withdrawAmount);
        assertEq(lentBalance, depositAmount);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - withdrawAmount
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(user2.balance, userETHBalance + withdrawAmount);
    }
}
