// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract NativeUniversalBalanceMultiDepositForTest is
    TestBaseNativeUniversalBalance
{
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

    function test_nativeUniversalBalanceMultiDepositFor_fail_whenLengthsAreMismatch(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareWETH(user1, depositSum);

        vm.startPrank(user1);

        amounts.push(1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        nativeUniversalBalance.multiDepositFor(
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
        nativeUniversalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceMultiDepositFor_fail_whenRecipientIsNotApproved(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareWETH(user1, depositSum);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), depositSum);

        recipients[0] = address(1);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(0xcfdc5602);
        nativeUniversalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceMultiDepositFor_fail_whenHasNoEnoughWETH_fuzzed(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareWETH(user1, depositSum);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), depositSum + 1);

        vm.expectRevert();
        nativeUniversalBalance.multiDepositFor(
            depositSum + 1,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceMultiDepositFor_fail_whenExceedsAllowance_fuzzed(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareWETH(user1, depositSum + 1);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), depositSum);

        vm.expectRevert();
        nativeUniversalBalance.multiDepositFor(
            depositSum + 1,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceMultiDepositFor_fail_whenTokenIsNotListed(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareWETH(user1, depositSum);

        eWETH = _deployEToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        for (uint256 i; i < 3; i++) {
            vm.prank(recipients[i]);
            nativeUniversalBalance.setDelegateApproval(user1, true);
        }

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), depositSum);

        willLend[0] = true;

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        nativeUniversalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceMultiDepositFor_fail_whenAmountIsZero(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareWETH(user1, depositSum);

        amounts[0] = 0;
        willLend[0] = false;

        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        nativeUniversalBalance.multiDepositFor(
            depositSum,
            amounts,
            willLend,
            recipients
        );
    }

    function test_nativeUniversalBalanceMultiDepositFor_fail_whenSumIsInvalid(
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        _prepareWETH(user1, depositSum);

        vm.prank(user1);

        vm.expectRevert();
        nativeUniversalBalance.multiDepositFor(
            depositSum - 1,
            amounts,
            willLend,
            recipients
        );
    }

    function test_nativeUniversalBalanceMultiDepositFor_success_fuzzed(
        uint256 exceedDepositAmount,
        uint256[3] memory amounts_,
        bool[3] memory willLend_
    ) public setupVariables(amounts_, willLend_) {
        vm.assume(exceedDepositAmount < 100e18);

        _prepareWETH(user1, depositSum + exceedDepositAmount);

        uint256[] memory receiveAmounts = new uint256[](3);

        for (uint256 i; i < 3; i++) {
            receiveAmounts[i] = eWETH.convertToShares(amounts[i]);
        }

        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(
            address(nativeUniversalBalance),
            depositSum + exceedDepositAmount
        );

        for (uint256 i; i < 3; i++) {
            vm.expectEmit();
            emit Deposit(user1, recipients[i], amounts[i], willLend[i]);
        }

        nativeUniversalBalance.multiDepositFor(
            depositSum + exceedDepositAmount,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();

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
            eWETH.balanceOf(address(nativeUniversalBalance)),
            eWETHBalance + lentAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - depositSum);
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
