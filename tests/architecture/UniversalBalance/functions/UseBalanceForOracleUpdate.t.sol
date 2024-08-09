// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract UseBalanceForOracleUpdateTest is TestBaseUniversalBalance {
    function setUp() public override {
        super.setUp();

        deal(_WETH_ADDRESS, address(this), 10e18);
        deal(user1, _ONE * 2);

        weth.approve(address(dWETH), 10e18);
        marketManager.listToken(address(dWETH));
        oracleRouter.addMTokenSupport(address(dWETH));
        
        vm.startPrank(user1);

        universalBalance.depositETH{ value: _ONE }(true);
        universalBalance.depositETH{ value: _ONE }(false);

        vm.stopPrank();
    }

    function test_useBalanceForOracleUpdate_fail_whenHasNoEnoughETH() public {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.useBalanceForOracleUpdate(user1, _ONE);
    }

    function test_useBalanceForOracleUpdate_fail_whenBalanceIsInsufficient()
        public
    {
        vm.prank(address(chainlinkAdaptor));

        vm.expectRevert(
            UniversalBalance.UniversalBalance__InsufficientBalance.selector
        );
        universalBalance.useBalanceForOracleUpdate(user1, _ONE * 2 + 1);
    }

    function test_useBalanceForOracleUpdate_success() public {
        uint256 redeemAmount = dWETH.convertToShares(_ONE);
        uint256 adaptorWETHBalance = weth.balanceOf(address(chainlinkAdaptor));
        uint256 wethBalance = weth.balanceOf(address(universalBalance));
        uint256 dWETHBalance = dWETH.balanceOf(address(universalBalance));
        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);

        assertEq(sittingBalance, _ONE);
        assertEq(lentBalance, _ONE);

        vm.prank(address(chainlinkAdaptor));
        universalBalance.useBalanceForOracleUpdate(user1, _ONE * 2);

        (sittingBalance, lentBalance) = universalBalance.userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(universalBalance)),
            wethBalance - _ONE
        );
        assertEq(
            dWETH.balanceOf(address(universalBalance)),
            dWETHBalance - redeemAmount
        );
        assertEq(
            weth.balanceOf(address(chainlinkAdaptor)),
            adaptorWETHBalance + _ONE * 2
        );
    }
}
