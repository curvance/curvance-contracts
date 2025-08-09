// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract MintTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenMint_fail_whenTransferZeroAmount() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );
        strategyCBALRETH.mint(0, address(this));
    }

    function test_strategyCTokenMint_fail_whenMintIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(strategyCBALRETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        strategyCBALRETH.mint(100, address(this));
    }

    function test_strategyCTokenMint_success() public {
        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = strategyCBALRETH.balanceOf(address(this));
        uint256 totalSupply = strategyCBALRETH.totalSupply();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit Transfer(address(0), address(this), 100);

        strategyCBALRETH.mint(100, address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance - 100);
        assertEq(strategyCBALRETH.balanceOf(address(this)), balance + 100);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply + 100);
    }
}
