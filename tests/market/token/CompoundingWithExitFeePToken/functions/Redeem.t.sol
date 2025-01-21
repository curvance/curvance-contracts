// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingWithExitFeePToken } from "../TestBaseCompoundingWithExitFeePToken.sol";
import { CompoundingPToken } from "contracts/market/token/CompoundingPToken.sol";

contract CompoundingWithExitFeePTokenPreviewWithdrawTest is
    TestBaseCompoundingWithExitFeePToken
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_compoundingWithExitFeePTokenRedeem_success() public {
        pBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = pBALRETHWithExitFee.totalSupply();

        uint256 quoteWithdraw = pBALRETHWithExitFee.previewRedeem(100);

    }
}
