// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract MultiDepositNativeForTest is TestBaseUniversalBalanceNative {
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
            universalBalanceNative.setDelegateApproval(user1, true);
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
        universalBalanceNative.multiDepositNativeFor{ value: depositSum }(
            amounts,
            willLend,
            recipients
        );

        amounts.pop();
        willLend.pop();

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalanceNative.multiDepositNativeFor{ value: depositSum }(
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
        vm.expectRevert(0xcfdc5602);
        universalBalanceNative.multiDepositNativeFor{ value: depositSum }(
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
        universalBalanceNative.multiDepositNativeFor{ value: depositSum + 1 }(
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

        eWETH = _deployEToken(_WETH_ADDRESS);

        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        for (uint256 i; i < 3; i++) {
            vm.prank(recipients[i]);
            universalBalanceNative.setDelegateApproval(user1, true);
        }

        willLend[0] = true;

        vm.prank(user1);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalanceNative.multiDepositNativeFor{ value: depositSum }(
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
        vm.expectRevert(0xc75f2a32);
        universalBalanceNative.multiDepositNativeFor{ value: depositSum }(
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
        universalBalanceNative.multiDepositNativeFor{ value: depositSum - 1 }(
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
            receiveAmounts[i] = eWETH.convertToShares(amounts[i]);
        }

        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user1.balance;

        for (uint256 i; i < 3; i++) {
            vm.expectEmit();
            emit Deposit(user1, recipients[i], amounts[i], willLend[i]);
        }

        vm.prank(user1);
        universalBalanceNative.multiDepositNativeFor{
            value: depositSum + exceedDepositAmount
        }(amounts, willLend, recipients);

        uint256 lentAmount = 0;
        uint256 sittingAmount = 0;

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = universalBalanceNative.userBalances(recipients[i]);

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
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + sittingAmount
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + lentAmount
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
