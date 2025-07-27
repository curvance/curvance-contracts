// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";

import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract MintTest is TestBaseStrategyCTokenWithExitFee {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenWithExitFeeMint_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );
        strategyCBALRETHWithExitFee.mint(0, address(this));
    }

    function test_strategyCTokenWithExitFeeMint_fail_whenMintIsNotAllowed()
        public
    {
        marketManagerIsolated.setMintPaused(address(strategyCBALRETHWithExitFee), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        strategyCBALRETHWithExitFee.mint(100, address(this));
    }

    function test_strategyCTokenWithExitFeeMint_success() public {
        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = strategyCBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = strategyCBALRETHWithExitFee.totalSupply();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETHWithExitFee));
        emit Transfer(address(0), address(this), 100);

        strategyCBALRETHWithExitFee.mint(100, address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance - 100);
        assertEq(strategyCBALRETHWithExitFee.balanceOf(address(this)), balance + 100);
        assertEq(strategyCBALRETHWithExitFee.totalSupply(), totalSupply + 100);
    }
}
