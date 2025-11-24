// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract MintTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenMint_fail_whenTransferZeroAmount() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );
        pendleStrategyCTokenSTETH.mint(0, address(this));
    }

    function test_strategyCTokenMint_fail_whenMintIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(pendleStrategyCTokenSTETH), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        pendleStrategyCTokenSTETH.mint(100, address(this));
    }

    function test_strategyCTokenMint_success() public {
        uint256 underlyingBalance = LP_wstETH_24Dec2025.balanceOf(address(this));
        uint256 balance = pendleStrategyCTokenSTETH.balanceOf(address(this));
        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();

        vm.expectEmit(true, true, true, true, address(pendleStrategyCTokenSTETH));
        emit Transfer(address(0), address(this), 100);

        pendleStrategyCTokenSTETH.mint(100, address(this));

        assertEq(LP_wstETH_24Dec2025.balanceOf(address(this)), underlyingBalance - 100);
        assertEq(pendleStrategyCTokenSTETH.balanceOf(address(this)), balance + 100);
        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply + 100);
    }
}
