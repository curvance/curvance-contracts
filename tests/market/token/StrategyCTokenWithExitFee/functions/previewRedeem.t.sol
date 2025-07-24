// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { StrategyCToken } from "contracts/market/token/StrategyCToken.sol";

contract PreviewRedeemTest is TestBaseStrategyCTokenWithExitFee {
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
        assertEq(redeemQuote, 76319); //77877 - 2% exit fee = 76319.46

    }

}
