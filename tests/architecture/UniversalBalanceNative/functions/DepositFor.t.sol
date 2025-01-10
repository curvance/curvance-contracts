// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract UniversalBalanceNativeDepositForTest is
    TestBaseUniversalBalanceNative
{
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public override {
        super.setUp();

        vm.prank(user2);
        universalBalanceNative.setDelegateApproval(user1, true);
    }

    function test_universalBalanceNativeDepositFor_fail_whenRecipientIsNotApproved()
        public
    {
        _prepareWETH(user1, _ONE);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), _ONE);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalanceNative.depositFor(_ONE, true, address(1));

        vm.stopPrank();
    }

    function test_universalBalanceNativeDepositFor_fail_whenInsufficientBalance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareWETH(user1, amount);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), amount + 1);

        vm.expectRevert();
        universalBalanceNative.depositFor(amount + 1, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceNativeDepositFor_fail_whenExceedsAllowance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareWETH(user1, amount + 1);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), amount);

        vm.expectRevert();
        universalBalanceNative.depositFor(amount + 1, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceNativeDepositFor_fail_whenTokenIsNotListed()
        public
    {
        _prepareWETH(user1, _ONE);

        eWETH = _deployEToken(_WETH_ADDRESS);

        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        vm.prank(user2);
        universalBalanceNative.setDelegateApproval(user1, true);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), _ONE);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalanceNative.depositFor(_ONE, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceNativeDepositFor_fail_whenAmountIsZero()
        public
    {
        vm.prank(user1);

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalanceNative.depositFor(0, false, user2);
    }

    function test_universalBalanceNativeDepositFor_success_withLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        uint256 receiveAmount = eWETH.convertToShares(amount);
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), amount);

        vm.expectEmit();
        emit Deposit(user1, user2, amount, receiveAmount);

        universalBalanceNative.depositFor(amount, true, user2);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user2);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }

    function test_universalBalanceNativeDepositFor_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareWETH(user1, amount);

        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), amount);

        vm.expectEmit();
        emit Deposit(user1, user2, amount, amount);

        universalBalanceNative.depositFor(amount, false, user2);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user2);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + amount
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - amount);
    }
}
