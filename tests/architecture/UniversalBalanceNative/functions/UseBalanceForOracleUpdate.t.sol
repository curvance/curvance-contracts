// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative, UniversalBalance } from "contracts/architecture/UniversalBalanceNative.sol";

contract UseBalanceForOracleUpdateTest is TestBaseUniversalBalanceNative {
    function test_useBalanceForOracleUpdate_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalanceNative.useBalanceForOracleUpdate(user1, _ONE);
    }

    function test_useBalanceForOracleUpdate_fail_whenBalanceIsInsufficient()
        public
    {
        deal(user1, _ONE * 2);

        vm.startPrank(user1);

        universalBalanceNative.depositNative{ value: _ONE }(true);
        universalBalanceNative.depositNative{ value: _ONE }(false);

        vm.stopPrank();

        vm.prank(address(chainlinkAdaptor));

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InsufficientBalance.selector
        );
        universalBalanceNative.useBalanceForOracleUpdate(user1, _ONE * 2 + 1);
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

        universalBalanceNative.depositNative{ value: depositAmount1 }(true);
        universalBalanceNative.depositNative{ value: depositAmount2 }(false);

        vm.stopPrank();

        uint256 redeemAmount = eWETH.convertToShares(
            withdrawAmount > depositAmount2
                ? withdrawAmount - depositAmount2
                : 0
        );
        uint256 adaptorWETHBalance = weth.balanceOf(address(chainlinkAdaptor));
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(lentBalance, depositAmount1);
        assertEq(sittingBalance, depositAmount2);

        vm.prank(address(chainlinkAdaptor));
        universalBalanceNative.useBalanceForOracleUpdate(
            user1,
            withdrawAmount
        );

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
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
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance -
                (
                    withdrawAmount > depositAmount2
                        ? depositAmount2
                        : withdrawAmount
                )
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - redeemAmount
        );
        assertEq(
            weth.balanceOf(address(chainlinkAdaptor)),
            adaptorWETHBalance + withdrawAmount
        );
    }
}
