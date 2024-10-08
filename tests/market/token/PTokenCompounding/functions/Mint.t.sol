// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBasePTokenCompounding } from "../TestBasePTokenCompounding.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { PTokenCompounding } from "contracts/market/token/PTokenCompounding.sol";

contract PTokenCompoundingMintTest is TestBasePTokenCompounding {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_pTokenCompoundingMint_fail_whenTransferZeroAmount() public {
        vm.expectRevert(
            PTokenCompounding.PTokenCompounding__ZeroShares.selector
        );
        pBALRETH.mint(0, address(this));
    }

    function test_pTokenCompoundingMint_fail_whenMintIsNotAllowed() public {
        marketManager.setMintPaused(address(pBALRETH), true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        pBALRETH.mint(100, address(this));
    }

    function test_pTokenCompoundingMint_success() public {
        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETH.balanceOf(address(this));
        uint256 totalSupply = pBALRETH.totalSupply();

        vm.expectEmit(true, true, true, true, address(pBALRETH));
        emit Transfer(address(0), address(this), 100);

        pBALRETH.mint(100, address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance - 100);
        assertEq(pBALRETH.balanceOf(address(this)), balance + 100);
        assertEq(pBALRETH.totalSupply(), totalSupply + 100);
    }
}
