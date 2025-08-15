// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract NativeUniversalBalanceDepositTest is TestBaseNativeUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );

    function test_nativeUniversalBalanceDeposit_fail_whenInsufficientBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), amount + 1);

        vm.expectRevert();
        nativeUniversalBalance.deposit(amount + 1, true);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceDeposit_fail_whenExceedsAllowance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareWETH(user1, amount + 1);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), amount);

        vm.expectRevert();
        nativeUniversalBalance.deposit(amount + 1, true);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceDeposit_fail_whenTokenIsNotListed()
        public
    {
        _prepareWETH(user1, _ONE);

        borrowableCWETH = _deployBorrowableCToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), _ONE);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        nativeUniversalBalance.deposit(_ONE, true);

        vm.stopPrank();
    }

    function test_nativeUniversalBalanceDeposit_fail_whenAmountIsZero()
        public
    {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(bytes4(0xc75f2a32));
        nativeUniversalBalance.deposit(0, false);
    }

    function test_nativeUniversalBalanceDeposit_success_withLend_fuzzed(
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
        emit Deposit(user1, user1, amount, true);

        nativeUniversalBalance.deposit(amount, true);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }

    function test_nativeUniversalBalanceDeposit_success_withoutLend_fuzzed(
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
        emit Deposit(user1, user1, amount, false);

        nativeUniversalBalance.deposit(amount, false);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

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
