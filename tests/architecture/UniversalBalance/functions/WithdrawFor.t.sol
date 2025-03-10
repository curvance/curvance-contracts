// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

contract UniversalBalanceWithdrawForTest is TestBaseUniversalBalance {
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

    function test_universalBalanceWithdrawFor_fail_whenRecipientIsNotApproved()
        public
    {
        _prepareUSDC(user1, 1e6);

        vm.prank(user1);
        universalBalance.deposit(1e6, true);

        vm.prank(user2);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(0xcfdc5602);
        universalBalance.withdrawFor(1e6, true, user2, address(1));
    }

    function test_universalBalanceWithdrawFor_fail_whenTransferIsDisabled()
        public
    {
        vm.prank(user1);
        centralRegistry.setTransferLockStatus(true);

        vm.prank(user2);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.withdrawFor(1e6, true, user2, user1);
    }

    function test_universalBalanceWithdrawFor_fail_whenCooldownIsNotEnded()
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
        universalBalance.withdrawFor(1e6, true, user2, user1);
    }

    function test_universalBalanceWithdrawFor_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        vm.prank(user1);
        universalBalance.deposit(amount, true);

        vm.prank(user2);

        vm.expectRevert();
        universalBalance.withdrawFor(amount + 1, true, user2, user1);
    }

    function test_universalBalanceWithdrawFor_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        vm.prank(user1);
        universalBalance.deposit(amount, false);

        vm.prank(user2);

        vm.expectRevert();
        universalBalance.withdrawFor(amount + 1, false, user2, user1);
    }

    function test_universalBalanceWithdrawFor_fail_whenAmountIsZero() public {
        vm.prank(user2);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.withdrawFor(0, false, user2, user1);
    }

    function test_universalBalanceWithdrawFor_success_withLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        _prepareUSDC(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.deposit(depositAmount, true);
        universalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 redeemAmount = eUSDC.convertToShares(withdrawAmount);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user2);

        vm.expectEmit();
        emit Withdraw(user2, user2, user1, withdrawAmount, true);

        vm.prank(user2);
        universalBalance.withdrawFor(withdrawAmount, true, user2, user1);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount);
        assertEq(lentBalance, depositAmount - withdrawAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance - redeemAmount
        );
        assertEq(usdc.balanceOf(user2), userUSDCBalance + withdrawAmount);
    }

    function test_universalBalanceWithdrawFor_success_withoutLend_fuzzed(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(
            0 < depositAmount && depositAmount < type(uint256).max / _ONE
        );
        vm.assume(0 < withdrawAmount && withdrawAmount <= depositAmount);

        _prepareUSDC(user1, depositAmount * 2);

        vm.startPrank(user1);

        universalBalance.deposit(depositAmount, true);
        universalBalance.deposit(depositAmount, false);

        vm.stopPrank();

        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user2);

        vm.expectEmit();
        emit Withdraw(user2, user2, user1, withdrawAmount, false);

        vm.prank(user2);
        universalBalance.withdrawFor(withdrawAmount, false, user2, user1);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, depositAmount - withdrawAmount);
        assertEq(lentBalance, depositAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance - withdrawAmount
        );
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
        assertEq(usdc.balanceOf(user2), userUSDCBalance + withdrawAmount);
    }
}
