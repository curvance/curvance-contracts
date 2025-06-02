// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract UniversalBalanceNativeTransferTest is TestBaseUniversalBalanceNative {
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

    function test_universalBalanceNativeTransfer_fail_whenTransferIsDisabled()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setTransferStatus(true);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalanceNative.transfer(_ONE, false, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceNativeTransfer_fail_whenCooldownIsNotEnded()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalanceNative.transfer(_ONE, false, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceNativeTransfer_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        universalBalanceNative.deposit(amount, true);

        vm.expectRevert();
        universalBalanceNative.transfer(amount + 1, true, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceNativeTransfer_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        universalBalanceNative.deposit(amount, false);

        vm.expectRevert();
        universalBalanceNative.transfer(amount + 1, false, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceNativeTransfer_fail_whenAmountIsZero()
        public
    {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalanceNative.transfer(0, false, true, user2);
    }

    function test_universalBalanceNativeTransfer_success_fuzzed(
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

        universalBalanceNative.deposit(depositAmount, true);
        universalBalanceNative.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 redeemAmount = eWETH.convertToShares(transferAmount);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userWETHBalance = weth.balanceOf(user2);

        vm.expectEmit();
        emit Withdraw(
            user1,
            user1,
            user1,
            transferAmount,
            forceLentRedemption
        );
        vm.expectEmit();
        emit Deposit(user1, user2, transferAmount, willLend);

        vm.prank(user1);
        universalBalanceNative.transfer(
            transferAmount,
            forceLentRedemption,
            willLend,
            user2
        );

        (
            uint256 user1SittingBalance,
            uint256 user1LentBalance
        ) = universalBalanceNative.userBalances(user1);
        (
            uint256 user2SittingBalance,
            uint256 user2LentBalance
        ) = universalBalanceNative.userBalances(user2);

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
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(weth.balanceOf(user2), userWETHBalance);

        if (forceLentRedemption && !willLend) {
            wethBalance += transferAmount;
            eWETHBalance -= redeemAmount;
        } else if (!forceLentRedemption && willLend) {
            wethBalance -= transferAmount;
            eWETHBalance += redeemAmount;
        }

        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
    }
}
