// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract ETokenMintForTest is TestBaseEToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_eTokenMintFor_fail_whenTransferZeroAmount() public {
        vm.expectRevert(EToken.EToken__EmptyAction.selector);
        eUSDC.mintFor(0, user1);
    }

    function test_eTokenMintFor_fail_whenMintIsNotAllowed() public {
        marketManagerIsolated.setMintPaused(address(eUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        eUSDC.mintFor(100e6, user1);
    }

    function test_eTokenMintFor_success() public {
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 user1Balance = eUSDC.balanceOf(user1);
        uint256 totalSupply = eUSDC.totalSupply();

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Transfer(address(0), user1, 100e6);

        eUSDC.mintFor(100e6, user1);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance);
        assertEq(eUSDC.balanceOf(user1), user1Balance + 100e6);
        assertEq(eUSDC.totalSupply(), totalSupply + 100e6);
    }
}
