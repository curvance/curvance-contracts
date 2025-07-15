// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RedeemTest is TestBaseStrategyCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_strategyCTokenRedeem_fail_whenNoEnoughToRedeem() public {
        vm.prank(address(1));

        vm.expectRevert();
        strategyCBALRETH.redeem(100, address(this), address(this));
    }

    function test_strategyCTokenRedeem_fail_whenTransferIsDisabled()
        public
    {
        strategyCBALRETH.mint(100, address(this));

        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        strategyCBALRETH.redeem(10, address(this), address(this));
    }

    function test_strategyCTokenRedeem_fail_whenCooldownIsNotEnded()
        public
    {
        strategyCBALRETH.mint(100, address(this));

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        strategyCBALRETH.redeem(10, address(this), address(this));
    }

    function test_strategyCTokenRedeem_fail_whenAmountIsZero() public {
        strategyCBALRETH.mint(100, address(this));

        vm.expectRevert(
            BaseCToken.BaseCToken__ZeroAmount.selector
        );
        strategyCBALRETH.redeem(0, address(this), address(this));
    }

    function test_strategyCTokenRedeem_success() public {
        strategyCBALRETH.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = strategyCBALRETH.balanceOf(address(this));
        uint256 totalSupply = strategyCBALRETH.totalSupply();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETH));
        emit Transfer(address(this), address(0), 100);

        strategyCBALRETH.redeem(100, address(this), address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance + 100);
        assertEq(strategyCBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(strategyCBALRETH.totalSupply(), totalSupply - 100);
    }
}
