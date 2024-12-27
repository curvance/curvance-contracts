// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract UniversalBalanceTransferForTest is TestBaseUniversalBalance {
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

    function setUp() public override {
        super.setUp();

        vm.prank(user1);
        universalBalance.setDelegateApproval(user2, true);
    }

    function test_universalBalanceTransferFor_fail_whenOwnerIsNotApproved()
        public
    {
        deal(_USDC_ADDRESS, user1, 1e6);

        vm.prank(user1);
        universalBalance.deposit(1e6, true);

        vm.prank(user2);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.transferFor(1e6, false, true, user2, address(1));
    }

    function test_universalBalanceTransferFor_fail_whenTransferIsDisabled()
        public
    {
        vm.prank(user1);
        centralRegistry.setTransferLockStatus(true);

        vm.prank(user2);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.transferFor(1e6, false, true, user2, user1);
    }

    function test_universalBalanceTransferFor_fail_whenCooldownIsNotEnded()
        public
    {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.stopPrank();

        vm.prank(user2);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.transferFor(1e6, false, true, user2, user1);
    }

    function test_universalBalanceTransferFor_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(_USDC_ADDRESS, user1, amount);

        vm.prank(user1);
        universalBalance.deposit(amount, true);

        vm.prank(user2);

        vm.expectRevert();
        universalBalance.transferFor(amount + 1, true, true, user2, user1);
    }

    function test_universalBalanceTransferFor_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(_USDC_ADDRESS, user1, amount);

        vm.prank(user1);
        universalBalance.deposit(amount, false);

        vm.prank(user2);

        vm.expectRevert();
        universalBalance.transferFor(amount + 1, false, true, user2, user1);
    }

    function test_universalBalanceTransferFor_fail_whenAmountIsZero() public {
        vm.prank(user2);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.transferFor(0, false, true, user2, user1);
    }

    function test_universalBalanceTransferFor_success_fuzzed(
        uint256 depositAmount,
        uint256 transferAmount,
        bool forceLentRedemption,
        bool willLend
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < transferAmount && transferAmount <= depositAmount);

        deal(_USDC_ADDRESS, user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.deposit(depositAmount, true);
        universalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 redeemAmount = eUSDC.convertToShares(transferAmount);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user2);

        vm.expectEmit();
        emit Withdraw(
            user2,
            user2,
            user1,
            transferAmount,
            forceLentRedemption
        );
        vm.expectEmit();
        emit Deposit(user2, user2, transferAmount, willLend);

        vm.prank(user2);
        universalBalance.transferFor(
            transferAmount,
            forceLentRedemption,
            willLend,
            user2,
            user1
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
            eUSDCBalance -= redeemAmount;
        } else if (!forceLentRedemption && willLend) {
            usdcBalance -= transferAmount;
            eUSDCBalance += redeemAmount;
        }

        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
    }
}
