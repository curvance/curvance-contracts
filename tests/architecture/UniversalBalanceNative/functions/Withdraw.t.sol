// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";

contract UniversalBalanceNativeWithdrawTest is TestBaseUniversalBalanceNative {
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

        universalBalanceNative.depositNative{ value: amount }(true);

        vm.expectRevert();
        universalBalanceNative.withdraw(amount + 1, true, address(this));

        vm.stopPrank();
    }

    function test_withdraw_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        universalBalanceNative.depositNative{ value: amount }(false);

        vm.expectRevert();
        universalBalanceNative.withdraw(amount + 1, false, address(this));

        vm.stopPrank();
    }

    function test_withdraw_fail_whenAmountIsZero() public {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        universalBalanceNative.withdraw(0, false, address(this));
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

        universalBalanceNative.depositNative{ value: depositAmount }(true);
        universalBalanceNative.depositNative{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 redeemAmount = eWETH.convertToShares(withdrawAmount);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userWETHBalance = weth.balanceOf(user2);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user2, user1, withdrawAmount, redeemAmount);

        universalBalanceNative.withdraw(withdrawAmount, true, user2);

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
        assertEq(weth.balanceOf(user2), userWETHBalance + withdrawAmount);
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

        universalBalanceNative.depositNative{ value: depositAmount }(true);
        universalBalanceNative.depositNative{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user2, user1, withdrawAmount, withdrawAmount);

        universalBalanceNative.withdraw(withdrawAmount, false, user2);

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
        assertEq(weth.balanceOf(user2), userWETHBalance + withdrawAmount);
    }
}
