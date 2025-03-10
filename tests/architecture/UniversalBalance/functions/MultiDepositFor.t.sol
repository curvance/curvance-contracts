// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract UniversalBalanceMultiDepositForTest is TestBaseUniversalBalance {
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
            universalBalance.setDelegateApproval(user1, true);
        }
    }

    function test_universalBalanceMultiDepositFor_fail_whenLengthsAreMismatch(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareUSDC(user1, depositSum);

        vm.startPrank(user1);

        amounts.push(1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );

        amounts.pop();
        willLend.pop();

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_universalBalanceMultiDepositFor_fail_whenRecipientIsNotApproved(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareUSDC(user1, depositSum);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), depositSum);

        recipients[0] = address(1);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(0xcfdc5602);

        universalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_universalBalanceMultiDepositFor_fail_whenHasNoEnoughUSDC_fuzzed(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareUSDC(user1, depositSum);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), depositSum + 1);

        vm.expectRevert();
        universalBalance.multiDepositFor(
            depositSum + 1,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_universalBalanceMultiDepositFor_fail_whenExceedsAllowance_fuzzed(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareUSDC(user1, depositSum + 1);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), depositSum);

        vm.expectRevert();
        universalBalance.multiDepositFor(
            depositSum + 1,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_universalBalanceMultiDepositFor_fail_whenTokenIsNotListed(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareUSDC(user1, depositSum);

        eUSDC = _deployEUSDC();

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC)
        );

        for (uint256 i; i < 3; i++) {
            vm.prank(recipients[i]);
            universalBalance.setDelegateApproval(user1, true);
        }

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), depositSum);

        willLend[0] = true;

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_universalBalanceMultiDepositFor_fail_whenAmountIsZero(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareUSDC(user1, depositSum);

        amounts[0] = 0;
        willLend[0] = false;

        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        universalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );
    }

    function test_universalBalanceMultiDepositFor_fail_whenSumIsInvalid(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareUSDC(user1, depositSum);

        vm.prank(user1);

        vm.expectRevert();
        universalBalance.multiDepositFor(
            depositSum - 1,
            amounts,
            willLend,
            recipients
        );
    }

    function test_universalBalanceMultiDepositFor_success_fuzzed(
        uint256 exceedDepositAmount,
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        vm.assume(exceedDepositAmount < 100e6);

        _prepareUSDC(user1, depositSum + exceedDepositAmount);

        uint256[] memory receiveAmounts = new uint256[](3);

        for (uint256 i; i < 3; i++) {
            receiveAmounts[i] = eUSDC.convertToShares(amounts[i]);
        }

        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.startPrank(user1);

        usdc.approve(
            address(universalBalance),
            depositSum + exceedDepositAmount
        );

        for (uint256 i; i < 3; i++) {
            vm.expectEmit();
            emit Deposit(user1, recipients[i], amounts[i], willLend[i]);
        }

        universalBalance.multiDepositFor(
            depositSum + exceedDepositAmount,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();

        uint256 lentAmount = 0;
        uint256 sittingAmount = 0;

        for (uint256 i; i < 3; i++) {
            (uint256 sittingBalance, uint256 lentBalance) = universalBalance
                .userBalances(recipients[i]);

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
            usdc.balanceOf(address(universalBalance)),
            usdcBalance + sittingAmount
        );
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance + lentAmount
        );
        assertEq(usdc.balanceOf(user1), userUSDCBalance - depositSum);
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
