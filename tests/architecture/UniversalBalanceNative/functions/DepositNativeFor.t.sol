// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DepositNativeForTest is TestBaseUniversalBalanceNative {
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        bool lendingDeposit
    );

    function setUp() public override {
        super.setUp();

        vm.prank(user2);
        universalBalanceNative.setDelegateApproval(user1, true);
    }

    function test_depositNativeFor_fail_whenRecipientIsNotApproved() public {
        deal(user1, _ONE);
        vm.prank(user1);
        
        // reverts with PluginDelegable__Unauthorized.selector
        vm.expectRevert(0xcfdc5602);
        universalBalanceNative.depositNativeFor{ value: _ONE }(
            true,
            address(1)
        );
    }

    function test_depositNativeFor_fail_whenHasNoEnoughETH_fuzzed(
        uint256 amount
    ) public {
        vm.assume(amount < type(uint256).max);

        deal(user1, amount);

        vm.prank(user1);

        vm.expectRevert();
        universalBalanceNative.depositNativeFor{ value: amount + 1 }(
            true,
            user2
        );
    }

    function test_depositNativeFor_fail_whenTokenIsNotListed() public {
        eWETH = _deployEToken(_WETH_ADDRESS);

        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        vm.prank(user2);
        universalBalanceNative.setDelegateApproval(user1, true);

        vm.prank(user1);

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        universalBalanceNative.depositNativeFor{ value: _ONE }(true, user2);
    }

    function test_depositNativeFor_fail_whenAmountIsZero() public {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        universalBalanceNative.depositNativeFor{ value: 0 }(false, user2);
    }

    function test_depositNativeFor_success_withLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        uint256 receiveAmount = eWETH.convertToShares(amount);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user1.balance;

        vm.expectEmit();
        emit Deposit(user1, user2, amount, true);

        vm.prank(user1);
        universalBalanceNative.depositNativeFor{ value: amount }(true, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user2);

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

    function test_depositNativeFor_success_withoutLend_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 < amount && amount < type(uint256).max / _ONE);

        deal(user1, amount);

        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user1.balance;

        vm.expectEmit();
        emit Deposit(user1, user2, amount, false);

        vm.prank(user1);
        universalBalanceNative.depositNativeFor{ value: amount }(false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user2);

        assertEq(sittingBalance, amount);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + amount
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(user1.balance, userETHBalance - amount);
    }
}
