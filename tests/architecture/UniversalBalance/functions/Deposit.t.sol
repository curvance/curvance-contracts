// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract UniversalBalanceDepositTest is TestBaseUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function test_universalBalanceDeposit_fail_whenHasNoEnoughUSDC_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareUSDC(user1, amount);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), amount + 1);

        vm.expectRevert();
        universalBalance.deposit(amount + 1, true);

        vm.stopPrank();
    }

    function test_universalBalanceDeposit_fail_whenExceedsAllowance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareUSDC(user1, amount + 1);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), amount);

        vm.expectRevert();
        universalBalance.deposit(amount + 1, true);

        vm.stopPrank();
    }

    function test_universalBalanceDeposit_fail_whenTokenIsNotListed() public {
        _prepareUSDC(user1, 100e6);

        eUSDC = _deployEUSDC();

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC)
        );

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), 100e6);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalance.deposit(100e6, true);

        vm.stopPrank();
    }

    function test_universalBalanceDeposit_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.deposit(0, false);
    }

    function test_universalBalanceDeposit_success_withLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        uint256 receiveAmount = eUSDC.convertToShares(amount);
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), amount);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, receiveAmount);

        universalBalance.deposit(amount, true);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance + receiveAmount
        );
        assertEq(usdc.balanceOf(user1), userUSDCBalance - amount);
    }

    function test_universalBalanceDeposit_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), amount);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, amount);

        universalBalance.deposit(amount, false);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance + amount
        );
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
        assertEq(usdc.balanceOf(user1), userUSDCBalance - amount);
    }
}
