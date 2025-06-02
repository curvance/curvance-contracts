// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingPToken } from "../TestBaseCompoundingPToken.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract CompoundingPTokenRedeemTest is TestBaseCompoundingPToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_compoundingPTokenRedeem_fail_whenNoEnoughToRedeem() public {
        vm.prank(address(1));

        vm.expectRevert();
        pBALRETH.redeem(100, address(this), address(this));
    }

    function test_compoundingPTokenRedeem_fail_whenTransferIsDisabled()
        public
    {
        pBALRETH.mint(100, address(this));

        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        pBALRETH.redeem(10, address(this), address(this));
    }

    function test_compoundingPTokenRedeem_fail_whenCooldownIsNotEnded()
        public
    {
        pBALRETH.mint(100, address(this));

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        pBALRETH.redeem(10, address(this), address(this));
    }

    function test_compoundingPTokenRedeem_fail_whenAmountIsZero() public {
        pBALRETH.mint(100, address(this));

        vm.expectRevert(
            BasePToken.BasePToken__EmptyAction.selector
        );
        pBALRETH.redeem(0, address(this), address(this));
    }

    function test_compoundingPTokenRedeem_success() public {
        pBALRETH.mint(100, address(this));

        uint256 underlyingBalance = balRETH.balanceOf(address(this));
        uint256 balance = pBALRETH.balanceOf(address(this));
        uint256 totalSupply = pBALRETH.totalSupply();

        vm.expectEmit(true, true, true, true, address(pBALRETH));
        emit Transfer(address(this), address(0), 100);

        pBALRETH.redeem(100, address(this), address(this));

        assertEq(balRETH.balanceOf(address(this)), underlyingBalance + 100);
        assertEq(pBALRETH.balanceOf(address(this)), balance - 100);
        assertEq(pBALRETH.totalSupply(), totalSupply - 100);
    }
}
