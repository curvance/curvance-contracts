// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract UniversalBalanceMultiWithdrawForTest is TestBaseUniversalBalance {
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
            universalBalance.setDelegateApproval(user1, true);
        }
    }

    function test_universalBalanceMultiWithdrawFor_fail_whenLengthsAreMismatch(
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
        universalBalance.multiWithdrawFor(
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
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        vm.stopPrank();
    }

    function test_universalBalanceMultiWithdrawFor_fail_whenRecipientIsNotApproved(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        owners[0] = address(1);

        vm.prank(user1);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceMultiWithdrawFor_fail_whenTransferIsDisabled(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        vm.prank(user2);
        centralRegistry.setTransferableStatus(true);

        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceMultiWithdrawFor_fail_whenCooldownIsNotEnded(
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
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceMultiWithdrawFor_fail_whenExceedsLentBalance_fuzzed(
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
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceMultiWithdrawFor_fail_whenExceedsSittingBalance_fuzzed(
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
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceMultiWithdrawFor_fail_whenAmountIsZero(
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
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );
    }

    function test_universalBalanceMultiWithdrawFor_success_fuzzed(
        uint256[3] memory depositAmounts,
        uint256[3] memory withdrawAmounts_,
        bool[3] memory forceLentRedemption_
    )
        public
        setupVariables(depositAmounts, withdrawAmounts_, forceLentRedemption_)
    {
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 borrowableCUSDCBalance = borrowableCUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

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
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        for (uint256 i; i < 3; i++) {
            (uint256 sittingBalance, uint256 lentBalance) = universalBalance
                .userBalances(owners[i]);

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

        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance - sittingAmountUsed
        );
        assertEq(
            borrowableCUSDC.balanceOf(address(universalBalance)),
            borrowableCUSDCBalance - lentAmountUsed
        );
        assertEq(usdc.balanceOf(user1), userUSDCBalance + withdrawSum);
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

            _prepareUSDC(owners[i], depositAmounts[i] * 2);

            vm.startPrank(owners[i]);

            usdc.approve(address(universalBalance), depositAmounts[i] * 2);
            universalBalance.deposit(depositAmounts[i], true);
            universalBalance.deposit(depositAmounts[i], false);

            vm.stopPrank();

            withdrawAmounts.push(withdrawAmounts_[i]);
            forceLentRedemption.push(forceLentRedemption_[i]);

            withdrawSum += withdrawAmounts_[i];
        }
        _;
    }
}
