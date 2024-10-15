// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative, UniversalBalance } from "contracts/architecture/UniversalBalanceNative.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DepositTest is TestBaseUniversalBalanceNative {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function test_deposit_fail_whenInsufficientBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        deal(_WETH_ADDRESS, user1, amount);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), amount + 1);

        vm.expectRevert();
        universalBalanceNative.deposit(amount + 1, true);

        vm.stopPrank();
    }

    function test_deposit_fail_whenExceedsAllowance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        deal(_WETH_ADDRESS, user1, amount + 1);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), amount);

        vm.expectRevert();
        universalBalanceNative.deposit(amount + 1, true);

        vm.stopPrank();
    }

    function test_deposit_fail_whenTokenIsNotListed() public {
        deal(_WETH_ADDRESS, user1, _ONE);

        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC),
            _WETH_ADDRESS
        );

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), _ONE);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalanceNative.deposit(_ONE, true);

        vm.stopPrank();
    }

    function test_deposit_fail_whenAmountIsZero() public {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        universalBalanceNative.deposit(0, false);
    }

    function test_deposit_success_withLend_fuzzed(uint256 amount) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(_WETH_ADDRESS, user1, amount);

        uint256 receiveAmount = eWETH.convertToShares(amount);
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalanceNative));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), amount);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, receiveAmount);

        universalBalanceNative.deposit(amount, true);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }

    function test_deposit_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(_WETH_ADDRESS, user1, amount);

        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalanceNative));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), amount);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, amount);

        universalBalanceNative.deposit(amount, false);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + amount
        );
        assertEq(eWETH.balanceOf(address(universalBalanceNative)), eWETHBalance);
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }
}
