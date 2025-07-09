// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract ETokenWithdrawReservesTest is TestBaseEToken {
    function test_eTokenWithdrawReserves_fail_whenCallIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.withdrawReserves(100e6);
    }

    function test_eTokenWithdrawReserves_fail_whenAmountIsZero() public {
        vm.expectRevert();
        borrowableCUSDC.withdrawReserves(0);
    }

    function test_eTokenWithdrawReserves_whenAmountExceedsTotalReserves()
        public
    {
        uint256 totalReserves = borrowableCUSDC.totalReserves();

        vm.expectRevert();
        borrowableCUSDC.withdrawReserves(totalReserves + 1);
    }

    function test_eTokenWithdrawReserves_success() public {
        borrowableCUSDC.depositReserves(100e6);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();

        borrowableCUSDC.withdrawReserves(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
    }
}
