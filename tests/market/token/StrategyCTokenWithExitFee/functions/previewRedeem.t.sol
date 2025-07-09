// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { StrategyCToken } from "contracts/market/token/StrategyCToken.sol";

// NOTES:
// [FAIL: assertion failed: 76319 != 41325] expected redeem quote to be 41325, but got 76319

contract StrategyCTokenWithExitFeePreviewRedeemTest is
    TestBaseStrategyCTokenWithExitFee
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenWithExitFeeRedeem_success() public {
        simpleCBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = simpleCBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = simpleCBALRETHWithExitFee.totalSupply();

        uint256 redeemQuote = simpleCBALRETHWithExitFee.previewRedeem(100);
        assertEq(redeemQuote, 98); // 100 - 2% exit fee = 98

    }

    function test_strategyCTokenWithExitFeeRedeem_All() public {
        simpleCBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = simpleCBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = simpleCBALRETHWithExitFee.totalSupply();

        uint256 redeemQuote = simpleCBALRETHWithExitFee.previewRedeem(totalSupply);
        assertEq(redeemQuote, 41325); // 42169 - 2% exit fee = 41325.62

    }

    // can't withdraw more than total supply
    // function test_strategyCTokenWithExitFeeRedeem_MoreThanTotalSupply() public {
    //     simpleCBALRETHWithExitFee.mint(100, address(this));

    //     uint256 underlyingBalance = balRETH.balanceOf(address(this));
    //     uint256 balance = simpleCBALRETHWithExitFee.balanceOf(address(this));
    //     uint256 totalSupply = simpleCBALRETHWithExitFee.totalSupply();

    //     uint256 redeemQuote = simpleCBALRETHWithExitFee.previewRedeem(totalSupply + 1);
       
    // }
}
