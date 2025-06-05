// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

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
        vm.expectRevert(0xcfdc5602);

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

        eUSDC = _deployEUSDC();

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC)
        );

        vm.prank(user2);
        universalBalance.setDelegateApproval(user1, true);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), 100e6);

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        universalBalance.depositFor(100e6, true, user2);

        vm.stopPrank();
    }

    function test_universalBalanceDepositFor_fail_whenAmountIsZero() public {
        vm.prank(user1);

        // `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
        vm.expectRevert(0xc75f2a32);
        universalBalance.depositFor(0, false, user2);
    }

    function test_universalBalanceDepositFor_success_withLend_fuzzed(
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
        emit Deposit(user1, user2, amount, true);

        universalBalance.depositFor(amount, true, user2);

        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user2);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, receiveAmount);
        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance + receiveAmount
        );
        assertEq(usdc.balanceOf(user1), userUSDCBalance - amount);
    }

    function test_universalBalanceDepositFor_success_withoutLend_fuzzed(
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
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
        assertEq(usdc.balanceOf(user1), userUSDCBalance - amount);
    }
}
