// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract MultiDepositNativeForTest is TestBaseNativeUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );

    uint256 public depositSum;
    uint256[] public amounts;
    bool[] public willLend;
    address[] public recipients;

    function setUp() public override {
        super.setUp();

        recipients.push(user2);
        recipients.push(user3);
        recipients.push(user4);

        for (uint256 i; i < 3; i++) {
            vm.prank(recipients[i]);
            nativeUniversalBalance.setDelegateApproval(user1, true);
        }
    }

    function test_multiDepositNativeFor_fail_whenLengthsAreMismatch(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        deal(user1, depositSum);

        vm.startPrank(user1);

        amounts.push(1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        nativeUniversalBalance.multiDepositNativeFor{ value: depositSum }(
            amounts,
            willLend,
            recipients
        );

        amounts.pop();
        willLend.pop();

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        nativeUniversalBalance.multiDepositNativeFor{ value: depositSum }(
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_multiDepositNativeFor_fail_whenRecipientIsNotApproved(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        deal(user1, depositSum);

        recipients[0] = address(1);

        vm.prank(user1);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        nativeUniversalBalance.multiDepositNativeFor{ value: depositSum }(
            amounts,
            willLend,
            recipients
        );
    }

    function test_multiDepositNativeFor_fail_whenHasNoEnoughWETH_fuzzed(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        deal(user1, depositSum);

        vm.prank(user1);

        vm.expectRevert();
        nativeUniversalBalance.multiDepositNativeFor{ value: depositSum + 1 }(
            amounts,
            willLend,
            recipients
        );
    }

    function test_multiDepositNativeFor_fail_whenTokenIsNotListed(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        deal(user1, depositSum);

        borrowableCWETH = _deployBorrowableCToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );

        for (uint256 i; i < 3; i++) {
            vm.prank(recipients[i]);
            nativeUniversalBalance.setDelegateApproval(user1, true);
        }

        willLend[0] = true;

        vm.prank(user1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        nativeUniversalBalance.multiDepositNativeFor{ value: depositSum }(
            amounts,
            willLend,
            recipients
        );
    }

    function test_multiDepositNativeFor_fail_whenAmountIsZero(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        deal(user1, depositSum);

        amounts[0] = 0;
        willLend[0] = false;

        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        nativeUniversalBalance.multiDepositNativeFor{ value: depositSum }(
            amounts,
            willLend,
            recipients
        );
    }

    function test_multiDepositNativeFor_fail_whenSumIsInvalid(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        deal(user1, depositSum);

        vm.prank(user1);

        vm.expectRevert();
        nativeUniversalBalance.multiDepositNativeFor{ value: depositSum - 1 }(
            amounts,
            willLend,
            recipients
        );
    }

    function test_multiDepositNativeFor_success_fuzzed(
        uint256 exceedDepositAmount,
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        vm.assume(exceedDepositAmount < 100e18);

        deal(user1, depositSum + exceedDepositAmount);

        uint256[] memory receiveAmounts = new uint256[](3);

        for (uint256 i; i < 3; i++) {
            receiveAmounts[i] = borrowableCWETH.convertToShares(amounts[i]);
        }

        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user1.balance;

        for (uint256 i; i < 3; i++) {
            vm.expectEmit();
            emit Deposit(user1, recipients[i], amounts[i], willLend[i]);
        }

        vm.prank(user1);
        nativeUniversalBalance.multiDepositNativeFor{
            value: depositSum + exceedDepositAmount
        }(amounts, willLend, recipients);

        uint256 lentAmount = 0;
        uint256 sittingAmount = 0;

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = nativeUniversalBalance.userBalances(recipients[i]);

            if (willLend[i]) {
                assertEq(sittingBalance, 0);
                assertEq(lentBalance, receiveAmounts[i]);
                lentAmount += receiveAmounts[i];
            } else {
                assertEq(sittingBalance, amounts[i]);
                assertEq(lentBalance, 0);
                sittingAmount += amounts[i];
            }
        }

        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + sittingAmount
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance + lentAmount
        );
        assertEq(user1.balance, userETHBalance - depositSum);
    }

    modifier setupVariables(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) {
        for (uint256 i; i < 3; i++) {
            vm.assume(
                0 < amounts_[i] && amounts_[i] < type(uint256).max / _ONE
            );

            amounts.push(amounts_[i]);
            willLend.push(willLend_[i]);

            depositSum += amounts_[i];
        }
        _;
    }
}
