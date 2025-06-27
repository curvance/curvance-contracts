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
        eUSDC.withdrawReserves(100e6);
    }

    function test_eTokenWithdrawReserves_fail_whenAmountIsZero() public {
        vm.expectRevert();
        eUSDC.withdrawReserves(0);
    }

    function test_eTokenWithdrawReserves_whenAmountExceedsTotalReserves()
        public
    {
        uint256 totalReserves = eUSDC.totalReserves();

        vm.expectRevert();
        eUSDC.withdrawReserves(totalReserves + 1);
    }

    function test_eTokenWithdrawReserves_success() public {
        eUSDC.depositReserves(100e6);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();

        eUSDC.withdrawReserves(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.totalSupply(), totalSupply);
    }
}
