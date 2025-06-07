// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingWithExitFeePToken } from "../TestBaseCompoundingWithExitFeePToken.sol";

import { BasePToken } from "contracts/market/token/BasePToken.sol";

contract CompoundingWithExitFeePTokenMintTest is
    TestBaseCompoundingWithExitFeePToken
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_compoundingWithExitFeePTokenMint_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(
            BasePToken.BasePToken__EmptyAction.selector
        );
        pBALRETHWithExitFee.mint(0, address(this));
    }

    function test_compoundingWithExitFeePTokenMint_fail_whenMintIsNotAllowed()
        public
    {
        marketManagerIsolated.setMintPaused(address(pBALRETHWithExitFee), true);

        vm.expectRevert(marketManagerIsolated.MarketManager__Paused.selector);
        pBALRETHWithExitFee.mint(100, address(this));
    }

    function test_compoundingWithExitFeePTokenMint_success() public {
        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = pBALRETHWithExitFee.totalSupply();

        vm.expectEmit(true, true, true, true, address(pBALRETHWithExitFee));
        emit Transfer(address(0), address(this), 100);

        pBALRETHWithExitFee.mint(100, address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance - 100);
        assertEq(pBALRETHWithExitFee.balanceOf(address(this)), balance + 100);
        assertEq(pBALRETHWithExitFee.totalSupply(), totalSupply + 100);
    }
}
