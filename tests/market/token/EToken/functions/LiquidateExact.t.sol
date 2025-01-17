// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { LiquidationManager } from "contracts/market/LiquidationManager.sol";

contract LiquidateExactTest is TestBaseEToken {
    function setUp() public override {
        super.setUp();

        _prepareLiquidation();
    }

    function test_liquidateExact_fail_whenLiquidationWindowHasPassed() public {
        centralRegistry.setSequencingStatus(true);

        vm.startPrank(user2, user2);

        eUSDC.queueLiquidation(user1, address(pBALRETH));
        usdc.approve(address(eUSDC), 250e6);

        skip(31);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));

        vm.stopPrank();
    }

    function test_liquidateExact_fail_whenUserOnlyQueuedAccountLiquidation()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.startPrank(user2, user2);

        marketManager.queueAccountLiquidation(user1);
        usdc.approve(address(eUSDC), 250e6);

        skip(1);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));

        vm.stopPrank();
    }

    function test_liquidateExact_success() public {
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), 250e6);
        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));
        vm.stopPrank();

        _checkLiquidationResult();
    }

    function test_liquidateExact_success_duringAtlasOev() public {
        address dappControl = makeAddr("dappControl");

        centralRegistry.setSequencingStatus(true);

        vm.prank(user2);
        usdc.approve(address(eUSDC), 250e6);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));

        centralRegistry.addAuthorizedAtlasDAppControl(dappControl);
        vm.prank(dappControl);
        centralRegistry.unlockAtlasOev();

        vm.prank(user2);
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));

        vm.prank(dappControl);
        centralRegistry.lockAtlasOev();

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, IMToken(address(pBALRETH)));

        _checkLiquidationResult();
    }

    function test_liquidateExact_success_withPriorityQueueLiquidation()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.startPrank(user2, user2);

        eUSDC.queueLiquidation(user1, address(pBALRETH));
        usdc.approve(address(eUSDC), 250e6);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));

        skip(1);

        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));

        vm.stopPrank();

        _checkLiquidationResult();
    }

    function test_liquidateExact_success_withDifferentUserAfterRegularDuration()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.prank(user3, user3);
        eUSDC.queueLiquidation(user1, address(pBALRETH));

        skip(2);

        vm.startPrank(user2, user2);

        usdc.approve(address(eUSDC), 250e6);

        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));

        vm.stopPrank();

        _checkLiquidationResult();
    }

    function test_liquidateExact_success_multipleTimes_withSamePriorityQueueLiquidation()
        public
    {
        centralRegistry.setSequencingStatus(true);

        vm.startPrank(user2, user2);

        eUSDC.queueLiquidation(user1, address(pBALRETH));
        usdc.approve(address(eUSDC), 250e6);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 125e6, address(pBALRETH));

        skip(1);

        eUSDC.liquidateExact(user1, 125e6, address(pBALRETH));

        eUSDC.liquidateExact(user1, 125e6, address(pBALRETH));

        vm.stopPrank();

        _checkLiquidationResult();
    }

    function test_liquidateExact_success_multipleTimes_withDifferentQueueLiquidation()
        public
    {
        centralRegistry.setSequencingStatus(true);

        _checkQueueNonce(0);

        vm.startPrank(user2, user2);

        usdc.approve(address(eUSDC), 250e6);

        eUSDC.queueLiquidation(user1, address(pBALRETH));

        _checkQueueNonce(1);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 125e6, address(pBALRETH));

        skip(1);

        eUSDC.liquidateExact(user1, 125e6, address(pBALRETH));

        skip(30);
        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 125e6, address(pBALRETH));

        eUSDC.queueLiquidation(user1, address(pBALRETH));

        _checkQueueNonce(2);

        skip(1);

        eUSDC.liquidateExact(user1, 125e6, address(pBALRETH));

        vm.stopPrank();

        _checkLiquidationResult();
    }

    function test_liquidateExact_success_withRegularQueueLiquidation() public {
        centralRegistry.setSequencingStatus(true);

        // Prepare user3 as liquidator
        _prepareUSDC(user3, 250 ether);

        vm.startPrank(user2, user2);

        eUSDC.queueLiquidation(user1, address(pBALRETH));
        usdc.approve(address(eUSDC), 250e6);

        vm.stopPrank();

        vm.startPrank(user3, user3);
        usdc.approve(address(eUSDC), 250e6);

        skip(1);

        vm.expectRevert(
            LiquidationManager.LiquidationManager__InvalidLiquidator.selector
        );
        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));

        skip(1);

        eUSDC.liquidateExact(user1, 250e6, address(pBALRETH));

        vm.stopPrank();

        _checkLiquidationResult();
    }

    function _checkQueueNonce(uint64 expectedNonce) internal {
        bytes32 queueKey = keccak256(abi.encodePacked(user1, address(eUSDC)));

        (, , , uint64 nonce) = marketManager.regularQueue(queueKey);

        assertEq(nonce, expectedNonce);
    }

    function _checkLiquidationResult() internal {
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
