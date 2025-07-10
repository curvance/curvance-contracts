// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseNativeUniversalBalance } from "../TestBaseNativeUniversalBalance.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DepositNativeTest is TestBaseNativeUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );

    function test_depositNative_fail_whenHasNoEnoughETH_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint216).max);

        deal(user1, amount);

        vm.prank(user1);

        vm.expectRevert();
        nativeUniversalBalance.depositNative{ value: amount + 1 }(true);
    }

    function test_depositNative_fail_whenTokenIsNotListed() public {
        borrowableCWETH = _deployBorrowableCToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );

        vm.prank(user1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        nativeUniversalBalance.depositNative{ value: _ONE }(true);
    }

    function test_depositNative_fail_whenAmountIsZero() public {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(bytes4(0xc75f2a32));
        nativeUniversalBalance.depositNative{ value: 0 }(false);
    }

    function test_depositNative_success_withLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint216).max / _ONE);

        deal(user1, amount);

        uint256 receiveAmount = borrowableCWETH.convertToShares(amount);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user1.balance;

        vm.expectEmit();
        emit Deposit(user1, user1, amount, true);

        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: amount }(true);

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance + receiveAmount
        );
        assertEq(user1.balance, userETHBalance - amount);
    }

    function test_depositNative_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint216).max / _ONE);

        deal(user1, amount);

        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user1.balance;

        vm.expectEmit();
        emit Deposit(user1, user1, amount, false);

        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: amount }(false);

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + amount
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
        assertEq(user1.balance, userETHBalance - amount);
    }
}
