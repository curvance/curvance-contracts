// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";

contract UniversalBalanceNativeMultiWithdrawForTest is
    TestBaseUniversalBalanceNative
{
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        bool lendingRedemption
    );

    uint256 public withdrawSum;
    uint256[] public withdrawAmounts;
    bool[] public forceLentRedemption;
    address[] public owners;

    function setUp() public override {
        super.setUp();

        owners.push(user2);
        owners.push(user3);
        owners.push(user4);

        for (uint256 i; i < 3; i++) {
            vm.prank(owners[i]);
            universalBalanceNative.setDelegateApproval(user1, true);
        }
    }

    function test_universalBalanceNativeMultiWithdrawFor_fail_whenLengthsAreMismatch(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        vm.startPrank(user1);

        withdrawAmounts.push(1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user2,
            owners
        );

        withdrawAmounts.pop();
        forceLentRedemption.pop();

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        vm.stopPrank();
    }

    function test_universalBalanceNativeMultiWithdrawFor_fail_whenRecipientIsNotApproved(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        owners[0] = address(1);

        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceNativeMultiWithdrawFor_fail_whenTransferIsDisabled(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        vm.prank(user2);
        centralRegistry.setTransferLockStatus(true);

        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceNativeMultiWithdrawFor_fail_whenCooldownIsNotEnded(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        vm.startPrank(user2);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.stopPrank();

        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceNativeMultiWithdrawFor_fail_whenExceedsLentBalance_fuzzed(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        vm.assume(forceLentRedemption[0]);

        withdrawAmounts[0] = depositAmounts[0] + 1;

        vm.prank(user1);

        vm.expectRevert();
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceNativeMultiWithdrawFor_fail_whenExceedsSittingBalance_fuzzed(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        vm.assume(!forceLentRedemption[0]);

        withdrawAmounts[0] = depositAmounts[0] * 2 + 1;

        vm.prank(user1);

        vm.expectRevert();
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceNativeMultiWithdrawFor_fail_whenAmountIsZero(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        withdrawAmounts[0] = 0;

        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceNativeMultiWithdrawFor_success_fuzzed(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        for (uint256 i; i < 3; i++) {
            vm.expectEmit();
            emit Withdraw(
                user1,
                user1,
                owners[i],
                withdrawAmounts[i],
                forceLentRedemption[i]
            );
        }

        vm.prank(user1);
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = universalBalanceNative.userBalances(owners[i]);

            if (forceLentRedemption[i]) {
                assertEq(sittingBalance, depositAmounts[i]);
                assertEq(lentBalance, depositAmounts[i] - withdrawAmounts[i]);
            } else {
                assertEq(
                    sittingBalance,
                    depositAmounts[i] - withdrawAmounts[i]
                );
                assertEq(lentBalance, depositAmounts[i]);
            }
        }

        uint256 lentAmountUsed = 0;
        uint256 sittingAmountUsed = 0;

        for (uint256 i; i < 3; i++) {
            if (forceLentRedemption[i]) {
                lentAmountUsed += withdrawAmounts[i];
            } else {
                sittingAmountUsed += withdrawAmounts[i];
            }
        }

        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - sittingAmountUsed
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - lentAmountUsed
        );
        assertEq(weth.balanceOf(user1), userWETHBalance + withdrawSum);
    }

    modifier setupVariables(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    ) {
        for (uint256 i; i < 3; i++) {
            vm.assume(
                0 < depositAmounts[i] &&
                    depositAmounts[i] < type(uint256).max / _ONE / 3
            );
            vm.assume(
                0 < withdrawAmounts_[i] &&
                    withdrawAmounts_[i] <= depositAmounts[i]
            );

            deal(_WETH_ADDRESS, owners[i], depositAmounts[i] * 2);

            vm.startPrank(owners[i]);

            weth.approve(
                address(universalBalanceNative),
                depositAmounts[i] * 2
            );
            universalBalanceNative.deposit(depositAmounts[i], true);
            universalBalanceNative.deposit(depositAmounts[i], false);

            vm.stopPrank();

            withdrawAmounts.push(withdrawAmounts_[i]);
            forceLentRedemption.push(forceLentRedemption_[i]);

            withdrawSum += withdrawAmounts_[i];
        }
        _;
    }
}
