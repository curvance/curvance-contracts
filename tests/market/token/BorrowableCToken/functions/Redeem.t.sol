// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract BorrowableCTokenRedeemTest is TestBaseBorrowableCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_borrowableCTokenRedeem_fail_whenNoEnoughToRedeem() public {
        vm.prank(address(1));

        vm.expectRevert();
        borrowableCUSDC.redeem(100e6, address(this), address(1));
    }

    function test_borrowableCTokenRedeem_fail_whenAmountIsZero() public {
        borrowableCUSDC.mint(100e6, address(this));

        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.redeem(0, address(this), address(this));
    }

    function test_borrowableCTokenRedeem_success() public {
        borrowableCUSDC.mint(100e6, address(this));

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Transfer(address(this), address(0), 100e6);

        borrowableCUSDC.redeem(100e6, address(this), address(this));

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply - 100e6);
    }

    function test_borrowableCTokenRedeemFor_success() public {
        borrowableCUSDC.mint(100e6, address(this));

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();

        borrowableCUSDC.setDelegateApproval(user1, true);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Transfer(address(this), address(0), 100e6);

        vm.prank(user1);
        borrowableCUSDC.redeemFor(100e6, address(this), address(this));

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply - 100e6);
    }
}
