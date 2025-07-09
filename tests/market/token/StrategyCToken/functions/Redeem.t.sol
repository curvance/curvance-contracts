// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract StrategyCTokenRedeemTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenRedeem_fail_whenNoEnoughToRedeem() public {
        vm.prank(address(1));

        vm.expectRevert();
        simpleCBALRETH.redeem(100, address(this), address(this));
    }

    function test_strategyCTokenRedeem_fail_whenTransferIsDisabled()
        public
    {
        simpleCBALRETH.mint(100, address(this));

        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        simpleCBALRETH.redeem(10, address(this), address(this));
    }

    function test_strategyCTokenRedeem_fail_whenCooldownIsNotEnded()
        public
    {
        simpleCBALRETH.mint(100, address(this));

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        simpleCBALRETH.redeem(10, address(this), address(this));
    }

    function test_strategyCTokenRedeem_fail_whenAmountIsZero() public {
        simpleCBALRETH.mint(100, address(this));

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );
        simpleCBALRETH.redeem(0, address(this), address(this));
    }

    function test_strategyCTokenRedeem_success() public {
        simpleCBALRETH.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = simpleCBALRETH.balanceOf(address(this));
        uint256 totalSupply = simpleCBALRETH.totalSupply();

        vm.expectEmit(true, true, true, true, address(simpleCBALRETH));
        emit Transfer(address(this), address(0), 100);

        simpleCBALRETH.redeem(100, address(this), address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance + 100);
        assertEq(simpleCBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(simpleCBALRETH.totalSupply(), totalSupply - 100);
    }
}
