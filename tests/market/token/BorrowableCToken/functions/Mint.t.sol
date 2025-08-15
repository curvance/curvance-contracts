// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract BorrowableCTokenMintTest is TestBaseBorrowableCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_borrowableCTokenMint_fail_whenTransferZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.mint(0, address(this));
    }

    function test_borrowableCTokenMint_fail_whenMintIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.mint(100e6, address(this));
    }

    //hopefully 1:1
    function test_borrowableCTokenMint_success() public {
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Transfer(address(0), address(this), 100e6);

        borrowableCUSDC.mint(100e6, address(this));

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance + 100e6);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply + 100e6);
    }
}
