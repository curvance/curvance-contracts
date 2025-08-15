// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";

contract UniversalBalanceDepositForTest is TestBaseUniversalBalance {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );

    function setUp() public override {
        super.setUp();

        vm.prank(user2);
        universalBalance.setDelegateApproval(user1, true);
    }

    function test_universalBalanceDepositFor_fail_whenRecipientIsNotApproved()
        public
    {
        _prepareUSDC(user1, 1e6);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), 1e6);
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);

        universalBalance.depositFor(1e6, true, address(1));

        vm.stopPrank();
    }

    function test_universalBalanceDepositFor_fail_whenHasNoEnoughUSDC_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareUSDC(user1, amount);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), amount + 1);

        vm.expectRevert();
        universalBalance.depositFor(amount + 1, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceDepositFor_fail_whenExceedsAllowance_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        _prepareUSDC(user1, amount + 1);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), amount);

        vm.expectRevert();
        universalBalance.depositFor(amount + 1, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceDepositFor_fail_whenTokenIsNotListed()
        public
    {
        _prepareUSDC(user1, 100e6);

        borrowableCUSDC = _deployBorrowableCUSDC();

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCUSDC)
        );

        vm.prank(user2);
        universalBalance.setDelegateApproval(user1, true);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), 100e6);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        universalBalance.depositFor(100e6, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceDepositFor_fail_whenAmountIsZero() public {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        universalBalance.depositFor(0, false, user2);
    }

    function test_universalBalanceDepositFor_success_withLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        uint256 receiveAmount = borrowableCUSDC.convertToShares(amount);
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 borrowableCUSDCBalance = borrowableCUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), amount);

        vm.expectEmit(true, true, true, true, address(universalBalance));
        emit Deposit(user1, user2, amount, true);

        universalBalance.depositFor(amount, true, user2);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user2);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(
            borrowableCUSDC.balanceOf(address(universalBalance)),
            borrowableCUSDCBalance + receiveAmount
        );
        assertEq(usdc.balanceOf(user1), userUSDCBalance - amount);
    }

    function test_universalBalanceDepositFor_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        _prepareUSDC(user1, amount);

        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 borrowableCUSDCBalance = borrowableCUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), amount);

        vm.expectEmit(true, true, true, true, address(universalBalance));
        emit Deposit(user1, user2, amount, false);

        universalBalance.depositFor(amount, false, user2);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user2);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance + amount
        );
        assertEq(borrowableCUSDC.balanceOf(address(universalBalance)), borrowableCUSDCBalance);
        assertEq(usdc.balanceOf(user1), userUSDCBalance - amount);
    }
}
