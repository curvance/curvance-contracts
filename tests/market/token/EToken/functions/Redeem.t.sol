// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { EToken } from "contracts/market/token/EToken.sol";

contract ETokenRedeemTest is TestBaseEToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_eTokenRedeem_fail_whenNoEnoughToRedeem() public {
        vm.prank(address(1));

        vm.expectRevert();
        eUSDC.redeem(100e6, address(this));
    }

    function test_eTokenRedeem_fail_whenAmountIsZero() public {
        eUSDC.mint(100e6);

        vm.expectRevert(EToken.EToken__EmptyAction.selector);
        eUSDC.redeem(0, address(this));
    }

    function test_eTokenRedeem_success() public {
        eUSDC.mint(100e6);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Transfer(address(this), address(0), 100e6);

        eUSDC.redeem(100e6, address(this));

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(eUSDC.totalSupply(), totalSupply - 100e6);
    }

    function test_eTokenRedeemFor_success() public {
        eUSDC.mint(100e6);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 totalSupply = eUSDC.totalSupply();

        eUSDC.setDelegateApproval(user1, true);

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Transfer(address(this), address(0), 100e6);

        vm.prank(user1);
        eUSDC.redeemFor(100e6, address(this), address(this));

        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(eUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(eUSDC.totalSupply(), totalSupply - 100e6);
    }
}
