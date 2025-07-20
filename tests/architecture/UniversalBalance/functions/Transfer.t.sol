// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract UniversalBalanceTransferTest is TestBaseUniversalBalance {
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

    function test_universalBalanceTransfer_fail_whenTransferIsDisabled()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.transfer(1e6, false, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceTransfer_fail_whenCooldownIsNotEnded()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.transfer(1e6, false, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceTransfer_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        vm.startPrank(user1);

        universalBalance.deposit(amount, true);

        vm.expectRevert();
        universalBalance.transfer(amount + 1, true, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceTransfer_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        vm.startPrank(user1);

        universalBalance.deposit(amount, false);

        vm.expectRevert();
        universalBalance.transfer(amount + 1, false, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceTransfer_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.transfer(0, false, true, user2);
    }

    function test_universalBalanceTransfer_success_fuzzed(
        uint256 depositAmount,
        uint256 transferAmount,
        bool forceLentRedemption,
        bool willLend
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < transferAmount && transferAmount <= depositAmount);

        _prepareUSDC(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.deposit(depositAmount, true);
        universalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 redeemAmount = borrowableCUSDC.convertToShares(transferAmount);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 borrowableCUSDCBalance = borrowableCUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user2);

        vm.expectEmit(true, true, false, true, address(universalBalance));
        emit Withdraw(
            user1,
            user1,
            user1,
            transferAmount,
            forceLentRedemption
        );
        vm.expectEmit(true, true, false, true, address(universalBalance));
        emit Deposit(user1, user2, transferAmount, willLend);

        vm.prank(user1);
        universalBalance.transfer(
            transferAmount,
            forceLentRedemption,
            willLend,
            user2
        );

        (
            uint256 user1SittingBalance,
            uint256 user1LentBalance
        ) = universalBalance.userBalances(user1);
        (
            uint256 user2SittingBalance,
            uint256 user2LentBalance
        ) = universalBalance.userBalances(user2);

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
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(usdc.balanceOf(user2), userUSDCBalance);

        if (forceLentRedemption && !willLend) {
            usdcBalance += transferAmount;
            borrowableCUSDCBalance -= redeemAmount;
        } else if (!forceLentRedemption && willLend) {
            usdcBalance -= transferAmount;
            borrowableCUSDCBalance += redeemAmount;
        }

        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(borrowableCUSDC.balanceOf(address(universalBalance)), borrowableCUSDCBalance);
    }

    function test_universalBalanceTransfer_fail_whenToAddressIsSelf() public {
        uint256 hundredUSDC = 100e6;

        _prepareUSDC(user1, hundredUSDC);

        vm.startPrank(user1);

        universalBalance.deposit(hundredUSDC, false);

        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        universalBalance.transfer(1e6, false, true, user1);
    }




}
