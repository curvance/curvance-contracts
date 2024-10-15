// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative, UniversalBalance } from "contracts/architecture/UniversalBalanceNative.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DepositNativeTest is TestBaseUniversalBalanceNative {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function test_depositNative_fail_whenHasNoEnoughETH_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        deal(user1, amount);

        vm.prank(user1);

        vm.expectRevert();
        universalBalanceNative.depositNative{ value: amount + 1 }(true);
    }

    function test_depositNative_fail_whenTokenIsNotListed() public {
        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC),
            _WETH_ADDRESS
        );

        vm.prank(user1);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalanceNative.depositNative{ value: _ONE }(true);
    }

    function test_depositNative_fail_whenAmountIsZero() public {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        universalBalanceNative.depositNative{ value: 0 }(false);
    }

    function test_depositNative_success_withLend_fuzzed(uint256 amount) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        uint256 receiveAmount = eWETH.convertToShares(amount);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalanceNative));
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, receiveAmount);

        universalBalanceNative.depositNative{ value: amount }(true);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + receiveAmount
        );
        assertEq(user1.balance, userETHBalance - amount);
    }

    function test_depositNative_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalanceNative));
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, amount);

        universalBalanceNative.depositNative{ value: amount }(false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + amount
        );
        assertEq(eWETH.balanceOf(address(universalBalanceNative)), eWETHBalance);
        assertEq(user1.balance, userETHBalance - amount);
    }
}
