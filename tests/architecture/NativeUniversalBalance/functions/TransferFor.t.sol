// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract NativeUniversalBalanceTransferForTest is
    TestBaseNativeUniversalBalance
{
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
        nativeUniversalBalance.setDelegateApproval(user2, true);
    }

    function test_nativeUniversalBalanceTransferFor_fail_whenOwnerIsNotApproved()
        public
    {
        _prepareWETH(user1, _ONE);

        vm.prank(user1);
        nativeUniversalBalance.deposit(_ONE, true);

        vm.prank(user2);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        nativeUniversalBalance.transferFor(
            _ONE,
            false,
            true,
            user2,
            address(1)
        );
    }

    function test_nativeUniversalBalanceTransferFor_fail_whenTransferIsDisabled()
        public
    {
        vm.prank(user1);
        centralRegistry.setTransferableStatus(true);

        vm.prank(user2);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        nativeUniversalBalance.transferFor(_ONE, false, true, user2, user1);
    }

    function test_nativeUniversalBalanceTransferFor_fail_whenCooldownIsNotEnded()
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
        nativeUniversalBalance.transferFor(_ONE, false, true, user2, user1);
    }

    function test_nativeUniversalBalanceTransferFor_fail_whenExceedsLentBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        vm.prank(user1);
        nativeUniversalBalance.deposit(amount, true);

        vm.prank(user2);

        vm.expectRevert();
        nativeUniversalBalance.transferFor(
            amount + 1,
            true,
            true,
            user2,
            user1
        );
    }

    function test_nativeUniversalBalanceTransferFor_fail_whenExceedsSittingBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        vm.prank(user1);
        nativeUniversalBalance.deposit(amount, false);

        vm.prank(user2);

        vm.expectRevert();
        nativeUniversalBalance.transferFor(
            amount + 1,
            false,
            true,
            user2,
            user1
        );
    }

    function test_nativeUniversalBalanceTransferFor_fail_whenAmountIsZero()
        public
    {
        vm.prank(user2);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        nativeUniversalBalance.transferFor(0, false, true, user2, user1);
    }

    function test_nativeUniversalBalanceTransferFor_success_fuzzed(
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

        uint256 redeemAmount = eWETH.convertToShares(transferAmount);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userWETHBalance = weth.balanceOf(user2);

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
        nativeUniversalBalance.transferFor(
            transferAmount,
            forceLentRedemption,
            willLend,
            user2,
            user1
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
            eWETHBalance -= redeemAmount;
        } else if (!forceLentRedemption && willLend) {
            wethBalance -= transferAmount;
            eWETHBalance += redeemAmount;
        }

        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(nativeUniversalBalance)),
            eWETHBalance
        );
    }
}
