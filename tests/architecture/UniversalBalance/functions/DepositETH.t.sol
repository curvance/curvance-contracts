// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DepositETHTest is TestBaseUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public override {
        super.setUp();

        deal(_WETH_ADDRESS, address(this), 10e18);
        deal(user1, _ONE);

        weth.approve(address(dWETH), 10e18);
        marketManager.listToken(address(dWETH));
        oracleRouter.addMTokenSupport(address(dWETH));
    }

    function test_depositETH_fail_whenHasNoEnoughETH_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        deal(user1, amount);

        vm.prank(user1);

        vm.expectRevert();
        universalBalance.depositETH{ value: amount + 1 }(true);
    }

    function test_depositETH_fail_whenTokenIsNotListed() public {
        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(dUSDC),
            _WETH_ADDRESS
        );

        vm.prank(user1);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalance.depositETH{ value: _ONE }(true);
    }

    function test_depositETH_fail_whenAmountIsZero() public {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.depositETH{ value: 0 }(false);
    }

    function test_depositETH_success_withLend_fuzzed(uint256 amount) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        uint256 receiveAmount = dWETH.convertToShares(amount);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, receiveAmount);

        universalBalance.depositETH{ value: amount }(true);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(address(universalBalance)), wethBalance);
        assertEq(
            dWETH.balanceOf(address(universalBalance)),
            dWETHBalance + receiveAmount
        );
        assertEq(user1.balance, userETHBalance - amount);
    }

    function test_depositETH_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        uint256 ethBalance = address(universalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, amount, amount);

        universalBalance.depositETH{ value: amount }(false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalance)),
            wethBalance + amount
        );
        assertEq(dWETH.balanceOf(address(universalBalance)), dWETHBalance);
        assertEq(user1.balance, userETHBalance - amount);
    }
}
