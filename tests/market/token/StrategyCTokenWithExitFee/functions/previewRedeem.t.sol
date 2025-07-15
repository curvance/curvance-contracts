// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { StrategyCToken } from "contracts/market/token/StrategyCToken.sol";

// NOTES:
// [FAIL: assertion failed: 76319 != 41325] expected redeem quote to be 41325, but got 76319

contract PreviewRedeemTest is
    TestBaseStrategyCTokenWithExitFee
{
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenWithExitFeeRedeem_success() public {
        strategyCBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = strategyCBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = strategyCBALRETHWithExitFee.totalSupply();

        uint256 redeemQuote = strategyCBALRETHWithExitFee.previewRedeem(100);
        assertEq(redeemQuote, 98); // 100 - 2% exit fee = 98

    }

    function test_strategyCTokenWithExitFeeRedeem_All() public {
        strategyCBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = strategyCBALRETHWithExitFee.balanceOf(address(this));
        uint256 totalSupply = strategyCBALRETHWithExitFee.totalSupply();

        uint256 redeemQuote = strategyCBALRETHWithExitFee.previewRedeem(totalSupply);
        assertEq(redeemQuote, 41325); // 42169 - 2% exit fee = 41325.62

    }

    // can't withdraw more than total supply
    // function test_strategyCTokenWithExitFeeRedeem_MoreThanTotalSupply() public {
    //     strategyCBALRETHWithExitFee.mint(100, address(this));

    //     uint256 underlyingBalance = balRETH.balanceOf(address(this));
    //     uint256 balance = strategyCBALRETHWithExitFee.balanceOf(address(this));
    //     uint256 totalSupply = strategyCBALRETHWithExitFee.totalSupply();

    //     uint256 redeemQuote = strategyCBALRETHWithExitFee.previewRedeem(totalSupply + 1);
       
    // }
}
