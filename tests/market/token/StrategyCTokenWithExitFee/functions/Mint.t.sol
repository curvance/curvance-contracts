// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";

import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract StrategyCTokenWithExitFeeMintTest is
    TestBaseStrategyCTokenWithExitFee
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenWithExitFeeMint_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );
        simpleCBALRETHWithExitFee.mint(0, address(this));
    }

    function test_strategyCTokenWithExitFeeMint_fail_whenMintIsNotAllowed()
        public
    {
        marketManagerIsolated.setMintPaused(address(simpleCBALRETHWithExitFee), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        simpleCBALRETHWithExitFee.mint(100, address(this));
    }

    function test_strategyCTokenWithExitFeeMint_success() public {
        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = simpleCBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = simpleCBALRETHWithExitFee.totalSupply();

        vm.expectEmit(true, true, true, true, address(simpleCBALRETHWithExitFee));
        emit Transfer(address(0), address(this), 100);

        simpleCBALRETHWithExitFee.mint(100, address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance - 100);
        assertEq(simpleCBALRETHWithExitFee.balanceOf(address(this)), balance + 100);
        assertEq(simpleCBALRETHWithExitFee.totalSupply(), totalSupply + 100);
    }
}
