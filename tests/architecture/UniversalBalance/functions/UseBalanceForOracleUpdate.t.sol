// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract UseBalanceForOracleUpdateTest is TestBaseUniversalBalance {
    function test_useBalanceForOracleUpdate_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.useBalanceForOracleUpdate(user1, _ONE);
    }

    function test_useBalanceForOracleUpdate_fail_whenBalanceIsInsufficient()
        public
    {
        deal(user1, _ONE * 2);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: _ONE }(true);
        universalBalance.depositETH{ value: _ONE }(false);

        vm.stopPrank();

        vm.prank(address(chainlinkAdaptor));

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InsufficientBalance.selector
        );
        universalBalance.useBalanceForOracleUpdate(user1, _ONE * 2 + 1);
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
        vm.assume(withdrawAmount <= depositAmount1 + depositAmount2);

        deal(user1, depositAmount1 + depositAmount2);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: depositAmount1 }(true);
        universalBalance.depositETH{ value: depositAmount2 }(false);

        vm.stopPrank();

        uint256 redeemAmount = dWETH.convertToShares(
            withdrawAmount > depositAmount2
                ? withdrawAmount - depositAmount2
                : 0
        );
        uint256 adaptorWETHBalance = weth.balanceOf(address(chainlinkAdaptor));
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(lentBalance, depositAmount1);
        assertEq(sittingBalance, depositAmount2);

        vm.prank(address(chainlinkAdaptor));
        universalBalance.useBalanceForOracleUpdate(user1, withdrawAmount);

        (sittingBalance, lentBalance) = universalBalance.userBalances(user1);

        assertEq(lentBalance, depositAmount1 - redeemAmount);
        assertEq(
            sittingBalance,
            withdrawAmount < depositAmount2
                ? depositAmount2 - withdrawAmount
                : 0
        );
        assertEq(
            weth.balanceOf(address(universalBalance)),
            wethBalance -
                (
                    withdrawAmount > depositAmount2
                        ? depositAmount2
                        : withdrawAmount
                )
        );
        assertEq(
            dWETH.balanceOf(address(universalBalance)),
            dWETHBalance - redeemAmount
        );
        assertEq(
            weth.balanceOf(address(chainlinkAdaptor)),
            adaptorWETHBalance + withdrawAmount
        );
    }
}
