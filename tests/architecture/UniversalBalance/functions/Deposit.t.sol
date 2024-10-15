// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DepositTest is TestBaseUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function test_deposit_fail_whenHasNoEnoughWETH_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        deal(_WETH_ADDRESS, user1, amount);

        vm.startPrank(user1);

        weth.approve(address(universalBalance), amount + 1);

        vm.expectRevert();
        universalBalance.deposit(amount + 1, true);

        vm.stopPrank();
    }

    function test_deposit_fail_whenExceedsAllowance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        deal(_WETH_ADDRESS, user1, amount + 1);

        vm.startPrank(user1);

        weth.approve(address(universalBalance), amount);

        vm.expectRevert();
        universalBalance.deposit(amount + 1, true);

        vm.stopPrank();
    }

    function test_deposit_fail_whenTokenIsNotListed() public {
        deal(_WETH_ADDRESS, user1, _ONE);

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC)
        );

        vm.startPrank(user1);

        weth.approve(address(universalBalance), _ONE);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalance.deposit(_ONE, true);

        vm.stopPrank();
    }

    function test_deposit_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.deposit(0, false);
    }

    function test_deposit_success_withLend_fuzzed(uint256 amount) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(_WETH_ADDRESS, user1, amount);

        uint256 receiveAmount = eWETH.convertToShares(amount);
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(universalBalance), amount);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, receiveAmount);

        universalBalance.deposit(amount, true);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(weth.balanceOf(address(universalBalance)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalance)),
            eWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }

    function test_deposit_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(_WETH_ADDRESS, user1, amount);

        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 eWETHBalance = eWETH.balanceOf(address(universalBalance));
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(universalBalance), amount);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, amount);

        universalBalance.deposit(amount, false);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(universalBalance)),
            wethBalance + amount
        );
        assertEq(eWETH.balanceOf(address(universalBalance)), eWETHBalance);
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }
}
