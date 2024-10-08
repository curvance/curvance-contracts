// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBasePTokenCompoundingWithExitFee } from "../TestBasePTokenCompoundingWithExitFee.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { PTokenCompounding } from "contracts/market/token/PTokenCompounding.sol";

contract PTokenCompoundingWithExitFeeMintTest is
    TestBasePTokenCompoundingWithExitFee
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_pTokenCompoundingWithExitFeeMint_fail_whenTransferZeroAmount()
        public
    {
        vm.expectRevert(
            PTokenCompounding.PTokenCompounding__ZeroShares.selector
        );
        pBALRETHWithExitFee.mint(0, address(this));
    }

    function test_pTokenCompoundingWithExitFeeMint_fail_whenMintIsNotAllowed()
        public
    {
        marketManager.setMintPaused(address(pBALRETHWithExitFee), true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        pBALRETHWithExitFee.mint(100, address(this));
    }

    function test_pTokenCompoundingWithExitFeeMint_success() public {
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
