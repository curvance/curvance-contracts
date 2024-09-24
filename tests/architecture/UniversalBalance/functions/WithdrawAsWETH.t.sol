// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract WithdrawAsWETHTest is TestBaseUniversalBalance {
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public override {
        super.setUp();

        deal(_WETH_ADDRESS, address(this), 10e18);

        weth.approve(address(dWETH), 10e18);
        marketManager.listToken(address(dWETH));
        oracleRouter.addMTokenSupport(address(dWETH));
    }

    function test_withdrawAsWETH_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: amount }(true);

        vm.expectRevert();
        universalBalance.withdrawAsWETH(amount + 1, true);

        vm.stopPrank();
    }

    function test_withdrawAsWETH_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: amount }(false);

        vm.expectRevert();
        universalBalance.withdrawAsWETH(amount + 1, false);

        vm.stopPrank();
    }

    function test_withdrawAsWETH_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.withdrawAsWETH(0, false);
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

        universalBalance.depositETH{ value: depositAmount }(true);
        universalBalance.depositETH{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 redeemAmount = dWETH.convertToShares(withdrawAmount);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, withdrawAmount, redeemAmount);

        universalBalance.withdrawAsWETH(withdrawAmount, true);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount);
        assertEq(lentBalance, depositAmount - withdrawAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(address(universalBalance)), wethBalance);
        assertEq(
            dWETH.balanceOf(address(universalBalance)),
            dWETHBalance - redeemAmount
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

        universalBalance.depositETH{ value: depositAmount }(true);
        universalBalance.depositETH{ value: depositAmount }(false);

        vm.stopPrank();

        uint256 ethBalance = address(universalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);

        vm.expectEmit();
        emit Withdraw(user1, user1, user1, withdrawAmount, withdrawAmount);

        universalBalance.withdrawAsWETH(withdrawAmount, false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount - withdrawAmount);
        assertEq(lentBalance, depositAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalance)),
            wethBalance - withdrawAmount
        );
        assertEq(dWETH.balanceOf(address(universalBalance)), dWETHBalance);
        assertEq(weth.balanceOf(user1), userWETHBalance + withdrawAmount);
    }
}
