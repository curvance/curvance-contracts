// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

contract LiquidateExactTest is TestBaseEToken {
    function setUp() public override {
        super.setUp();

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }

    function test_liquidateExact_success() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE - 1);

        // try borrow()
        eUSDC.borrow(1000e6);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        mockUsdcFeed.setMockAnswer(2e8);

        // try liquidate half
        _prepareUSDC(user2, 250e6);
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), 250e6);
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));
        vm.stopPrank();

        assertApproxEqRel(
            pBALRETH.balanceOf(user1),
            _ONE - (500e18 * _ONE) / balRETHPrice,
            0.02e18
        );
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertApproxEqRel(eUSDC.debtBalanceCached(user1), 750e6, 0.01e18);
        assertApproxEqRel(eUSDC.exchangeRateCached(), _ONE, 0.01e18);
    }
}
