// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract ETokenMintTest is TestBaseEToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_eTokenMint_fail_whenTransferZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        eUSDC.mint(0, address(this));
    }

    function test_eTokenMint_fail_whenMintIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(eUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        eUSDC.mint(100e6, address(this));
    }

    //hopefully 1:1
    function test_eTokenMint_success() public {
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Transfer(address(0), address(this), 100e6);

        eUSDC.mint(100e6, address(this));

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance + 100e6);
        assertEq(eUSDC.totalSupply(), totalSupply + 100e6);
    }
}
