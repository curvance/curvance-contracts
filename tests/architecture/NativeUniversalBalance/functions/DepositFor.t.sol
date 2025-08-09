// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract NativeUniversalBalanceDepositForTest is
    TestBaseNativeUniversalBalance
{
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );

    function setUp() public override {
        super.setUp();

        vm.prank(user2);
        nativeUniversalBalance.setDelegateApproval(user1, true);
    }

    function test_nativeUniversalBalanceDepositFor_fail_whenRecipientIsNotApproved()
        public
    {
        _prepareWETH(user1, _ONE);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), _ONE);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(bytes4(0xcfdc5602));
        
        nativeUniversalBalance.depositFor(_ONE, true, address(1));

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceDepositFor_fail_whenInsufficientBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), amount + 1);

        vm.expectRevert();
        nativeUniversalBalance.depositFor(amount + 1, true, user2);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceDepositFor_fail_whenExceedsAllowance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareWETH(user1, amount + 1);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), amount);

        vm.expectRevert();
        nativeUniversalBalance.depositFor(amount + 1, true, user2);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceDepositFor_fail_whenTokenIsNotListed()
        public
    {
        _prepareWETH(user1, _ONE);

        borrowableCWETH = _deployBorrowableCToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );

        vm.prank(user2);
        nativeUniversalBalance.setDelegateApproval(user1, true);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), _ONE);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        nativeUniversalBalance.depositFor(_ONE, true, user2);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceDepositFor_fail_whenAmountIsZero()
        public
    {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        nativeUniversalBalance.depositFor(0, false, user2);
    }

    function test_nativeUniversalBalanceDepositFor_success_withLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        uint256 receiveAmount = borrowableCWETH.convertToShares(amount);
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), amount);

        vm.expectEmit(true, true, true, true, address(nativeUniversalBalance));
        emit Deposit(user1, user2, amount, true);

        nativeUniversalBalance.depositFor(amount, true, user2);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user2);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }

    function test_nativeUniversalBalanceDepositFor_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), amount);

        vm.expectEmit(true, true, true, true, address(nativeUniversalBalance));
        emit Deposit(user1, user2, amount, false);

        nativeUniversalBalance.depositFor(amount, false, user2);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user2);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + amount
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }
}
