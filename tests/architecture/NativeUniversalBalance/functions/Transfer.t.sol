// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract NativeUniversalBalanceTransferTest is TestBaseNativeUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        bool lendingRedemption
    );

    function test_nativeUniversalBalanceTransfer_fail_whenTransferIsDisabled()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        nativeUniversalBalance.transfer(_ONE, false, true, user2);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceTransfer_fail_whenCooldownIsNotEnded()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        nativeUniversalBalance.transfer(_ONE, false, true, user2);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceTransfer_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        nativeUniversalBalance.deposit(amount, true);

        vm.expectRevert();
        nativeUniversalBalance.transfer(amount + 1, true, true, user2);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceTransfer_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        nativeUniversalBalance.deposit(amount, false);

        vm.expectRevert();
        nativeUniversalBalance.transfer(amount + 1, false, true, user2);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceTransfer_fail_whenAmountIsZero()
        public
    {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        nativeUniversalBalance.transfer(0, false, true, user2);
    }

    function test_nativeUniversalBalanceTransfer_success_fuzzed(
        uint256 depositAmount,
        uint256 transferAmount,
        bool forceLentRedemption,
        bool willLend
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < transferAmount && transferAmount <= depositAmount);

        _prepareWETH(user1, depositAmount * 2);

        vm.startPrank(user1);

        nativeUniversalBalance.deposit(depositAmount, true);
        nativeUniversalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 redeemAmount = borrowableCWETH.convertToShares(transferAmount);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userWETHBalance = weth.balanceOf(user2);

        vm.expectEmit(true, true, false, true, address(nativeUniversalBalance));
        emit Withdraw(
            user1,
            user1,
            user1,
            transferAmount,
            forceLentRedemption
        );
        vm.expectEmit(true, true, false, true, address(nativeUniversalBalance));
        emit Deposit(user1, user2, transferAmount, willLend);

        vm.prank(user1);
        nativeUniversalBalance.transfer(
            transferAmount,
            forceLentRedemption,
            willLend,
            user2
        );

        (
            uint256 user1SittingBalance,
            uint256 user1LentBalance
        ) = nativeUniversalBalance.userBalances(user1);
        (
            uint256 user2SittingBalance,
            uint256 user2LentBalance
        ) = nativeUniversalBalance.userBalances(user2);

        assertEq(
            user1SittingBalance,
            depositAmount - (forceLentRedemption ? 0 : transferAmount)
        );
        assertEq(
            user1LentBalance,
            depositAmount - (forceLentRedemption ? transferAmount : 0)
        );
        assertEq(user2SittingBalance, willLend ? 0 : transferAmount);
        assertEq(user2LentBalance, willLend ? transferAmount : 0);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(user2), userWETHBalance);

        if (forceLentRedemption && !willLend) {
            wethBalance += transferAmount;
            borrowableCWETHBalance -= redeemAmount;
        } else if (!forceLentRedemption && willLend) {
            wethBalance -= transferAmount;
            borrowableCWETHBalance += redeemAmount;
        }

        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
    }
}
