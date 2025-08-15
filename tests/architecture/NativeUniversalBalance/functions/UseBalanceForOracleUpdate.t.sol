// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract UseBalanceForOracleUpdateTest is TestBaseNativeUniversalBalance {
    function test_useBalanceForOracleUpdate_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        nativeUniversalBalance.useBalanceForOracleUpdate(user1, _ONE);
    }

    function test_useBalanceForOracleUpdate_fail_whenBalanceIsInsufficient()
        public
    {
        deal(user1, _ONE * 2);

        vm.startPrank(user1);

        nativeUniversalBalance.depositNative{ value: _ONE }(true);
        nativeUniversalBalance.depositNative{ value: _ONE }(false);

        vm.stopPrank();

        vm.prank(address(chainlinkAdaptor));

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InsufficientBalance.selector
        );
        nativeUniversalBalance.useBalanceForOracleUpdate(user1, _ONE * 2 + 1);
    }

    function test_useBalanceForOracleUpdate_success_fuzzed(
        uint256 depositAmount1,
        uint256 depositAmount2,
        uint256 withdrawAmount
    ) public {
        vm.assume(0 < depositAmount1 && 0 < depositAmount2);
        vm.assume(
            depositAmount1 < type(uint256).max / _ONE &&
                depositAmount2 < type(uint256).max / _ONE
        );
        vm.assume(
            0 < withdrawAmount &&
                withdrawAmount <= depositAmount1 + depositAmount2
        );

        deal(user1, depositAmount1 + depositAmount2);

        vm.startPrank(user1);

        nativeUniversalBalance.depositNative{ value: depositAmount1 }(true);
        nativeUniversalBalance.depositNative{ value: depositAmount2 }(false);

        vm.stopPrank();

        uint256 redeemAmount = borrowableCWETH.convertToShares(
            withdrawAmount > depositAmount2
                ? withdrawAmount - depositAmount2
                : 0
        );
        uint256 adaptorWETHBalance = weth.balanceOf(address(chainlinkAdaptor));
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(lentBalance, depositAmount1);
        assertEq(sittingBalance, depositAmount2);

        vm.prank(address(chainlinkAdaptor));
        nativeUniversalBalance.useBalanceForOracleUpdate(
            user1,
            withdrawAmount
        );

        (sittingBalance, lentBalance) = nativeUniversalBalance.userBalances(
            user1
        );

        assertEq(lentBalance, depositAmount1 - redeemAmount);
        assertEq(
            sittingBalance,
            withdrawAmount < depositAmount2
                ? depositAmount2 - withdrawAmount
                : 0
        );
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance -
                (
                    withdrawAmount > depositAmount2
                        ? depositAmount2
                        : withdrawAmount
                )
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance - redeemAmount
        );
        assertEq(
            weth.balanceOf(address(chainlinkAdaptor)),
            adaptorWETHBalance + withdrawAmount
        );
    }
}
