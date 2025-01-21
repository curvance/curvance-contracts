// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingWithExitFeePToken } from "../TestBaseCompoundingWithExitFeePToken.sol";
import { CompoundingPToken } from "contracts/market/token/CompoundingPToken.sol";

contract CompoundingWithExitFeePTokenPreviewRedeemTest is
    TestBaseCompoundingWithExitFeePToken
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_compoundingWithExitFeePTokenRedeem_success() public {
        pBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = pBALRETHWithExitFee.totalSupply();

        uint256 redeemQuote = pBALRETHWithExitFee.previewRedeem(100);
        assertEq(redeemQuote, 98); // 100 - 2% exit fee = 98

    }

    function test_compoundingWithExitFeePTokenRedeem_All() public {
        pBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = pBALRETHWithExitFee.totalSupply();

        uint256 redeemQuote = pBALRETHWithExitFee.previewRedeem(totalSupply);
        assertEq(redeemQuote, 41325); // 42169 - 2% exit fee = 41325.62

    }

    // can't withdraw more than total supply
    // function test_compoundingWithExitFeePTokenRedeem_MoreThanTotalSupply() public {
    //     pBALRETHWithExitFee.mint(100, address(this));

    //     uint256 underlyingBalance = balRETH.balanceOf(address(this));
    //     uint256 balance = pBALRETHWithExitFee.balanceOf(address(this));
    //     uint256 totalSupply = pBALRETHWithExitFee.totalSupply();

    //     uint256 redeemQuote = pBALRETHWithExitFee.previewRedeem(totalSupply + 1);
       
    // }
}
