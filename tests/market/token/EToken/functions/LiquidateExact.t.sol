// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { LiquidationManager } from "contracts/market/LiquidationManager.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

contract LiquidateExactTest is TestBaseEToken {
    function setUp() public override {
        super.setUp();

        _prepareLiquidation();
    }

    function test_liquidateExact_fail_whenLiquidationWindowHasPassed() public {
        centralRegistry.setSequencingStatus(true);

        vm.startPrank(user2, address(1));

        eUSDC.queueLiquidation(user1, IMToken(address(pBALRETH)));
        usdc.approve(address(eUSDC), 250e6);

        skip(31);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));

        vm.stopPrank();
    }

    function test_liquidateExact_success() public {
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), 250e6);
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));
        vm.stopPrank();

        _checkLiquidationResult();
    }

    function test_liquidateExact_success_byWhitelistedBundler() public {
        address bundler = makeAddr("bundler");

        centralRegistry.setSequencingStatus(true);

        vm.prank(user2);
        usdc.approve(address(eUSDC), 250e6);

        vm.prank(user2, bundler);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));

        centralRegistry.setBundler(bundler, true);

        vm.prank(user2, bundler);
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));

        _checkLiquidationResult();
    }

    function test_liquidateExact_success_withPriorityQueueLiquidation()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.startPrank(user2, address(1));

        eUSDC.queueLiquidation(user1, IMToken(address(pBALRETH)));
        usdc.approve(address(eUSDC), 250e6);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));

        skip(1);
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));

        vm.stopPrank();

        _checkLiquidationResult();
    }

    function _checkLiquidationResult() internal view {
        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

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
